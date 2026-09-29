#include "CIOKitMMC.h"

#include <stddef.h>

#if defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <stdlib.h>
#include <string.h>

struct BKMMCDevice {
    MMCDeviceInterface **mmc;
    SCSITaskDeviceInterface **task;
    bool exclusive;
};

static CFMutableDictionaryRef BKMMCCreateMatchingDictionary(void) {
    CFMutableDictionaryRef matching = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (matching == NULL || properties == NULL) {
        if (matching != NULL) CFRelease(matching);
        if (properties != NULL) CFRelease(properties);
        return NULL;
    }
    CFDictionarySetValue(properties, CFSTR(kIOPropertySCSITaskDeviceCategory),
                         CFSTR(kIOPropertySCSITaskAuthoringDevice));
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), properties);
    CFRelease(properties);
    return matching;
}

int BKMMCCopyDeviceIDs(uint64_t *ids, int maxCount) {
    CFMutableDictionaryRef matching = BKMMCCreateMatchingDictionary();
    if (matching == NULL) return 0;

    io_iterator_t iterator = IO_OBJECT_NULL;
    // IOServiceGetMatchingServices consumes the matching dictionary.
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return 0;
    }

    int found = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint64_t entryID = 0;
        if (IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS) {
            if (ids != NULL && found < maxCount) {
                ids[found] = entryID;
            }
            found += 1;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return found;
}

BKMMCDevice *BKMMCDeviceOpen(uint64_t registryID, int32_t *outError) {
    if (outError != NULL) *outError = 0;

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID));
    if (service == IO_OBJECT_NULL) {
        if (outError != NULL) *outError = kIOReturnNotFound;
        return NULL;
    }

    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(service, kIOMMCDeviceUserClientTypeID,
                                                        kIOCFPlugInInterfaceID, &plugIn, &score);
    IOObjectRelease(service);
    if (result != kIOReturnSuccess || plugIn == NULL) {
        if (outError != NULL) *outError = (result != kIOReturnSuccess) ? result : BKMMC_ERROR_NO_INTERFACE;
        return NULL;
    }

    MMCDeviceInterface **mmc = NULL;
    HRESULT queryResult = (*plugIn)->QueryInterface(plugIn, CFUUIDGetUUIDBytes(kIOMMCDeviceInterfaceID),
                                                    (LPVOID *)&mmc);
    IODestroyPlugInInterface(plugIn);
    if (queryResult != S_OK || mmc == NULL) {
        if (outError != NULL) *outError = BKMMC_ERROR_NO_INTERFACE;
        return NULL;
    }

    SCSITaskDeviceInterface **task = (*mmc)->GetSCSITaskDeviceInterface(mmc);
    if (task == NULL) {
        (*mmc)->Release(mmc);
        if (outError != NULL) *outError = BKMMC_ERROR_NO_INTERFACE;
        return NULL;
    }

    BKMMCDevice *device = calloc(1, sizeof(BKMMCDevice));
    if (device == NULL) {
        (*task)->Release(task);
        (*mmc)->Release(mmc);
        if (outError != NULL) *outError = kIOReturnNoMemory;
        return NULL;
    }
    device->mmc = mmc;
    device->task = task;
    device->exclusive = false;
    return device;
}

void BKMMCDeviceClose(BKMMCDevice *device) {
    if (device == NULL) return;
    BKMMCDeviceReleaseExclusiveAccess(device);
    (*device->task)->Release(device->task);
    (*device->mmc)->Release(device->mmc);
    free(device);
}

int32_t BKMMCDeviceObtainExclusiveAccess(BKMMCDevice *device) {
    if (device == NULL) return kIOReturnBadArgument;
    if (device->exclusive) return kIOReturnSuccess;
    IOReturn result = (*device->task)->ObtainExclusiveAccess(device->task);
    if (result == kIOReturnSuccess) device->exclusive = true;
    return result;
}

void BKMMCDeviceReleaseExclusiveAccess(BKMMCDevice *device) {
    if (device == NULL || !device->exclusive) return;
    (*device->task)->ReleaseExclusiveAccess(device->task);
    device->exclusive = false;
}

bool BKMMCDeviceHasExclusiveAccess(const BKMMCDevice *device) {
    return device != NULL && device->exclusive;
}

static uint32_t BKMMCReadUInt32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

// Sends the few read-only commands that MMCDeviceInterface offers without exclusive access.
static int32_t BKMMCExecuteShared(BKMMCDevice *device, const uint8_t *cdb, uint8_t cdbLength,
                                  void *buffer, uint64_t bufferLength,
                                  SCSITaskStatus *status, SCSI_Sense_Data *sense) {
    MMCDeviceInterface **mmc = device->mmc;
    uint16_t length16 = bufferLength > 0xFFFF ? 0xFFFF : (uint16_t)bufferLength;

    switch (cdb[0]) {
    case 0x00: // TEST UNIT READY
        return (*mmc)->TestUnitReady(mmc, status, sense);

    case 0x12: { // INQUIRY
        uint32_t length = (uint32_t)bufferLength;
        if (length > sizeof(SCSICmd_INQUIRY_StandardData)) length = sizeof(SCSICmd_INQUIRY_StandardData);
        return (*mmc)->Inquiry(mmc, (SCSICmd_INQUIRY_StandardData *)buffer, length, status, sense);
    }

    case 0x46: // GET CONFIGURATION
        if (cdbLength < 10) return kIOReturnBadArgument;
        return (*mmc)->GetConfiguration(mmc, cdb[1] & 0x03, (uint16_t)((cdb[2] << 8) | cdb[3]),
                                        buffer, length16, status, sense);

    case 0x51: // READ DISC INFORMATION
        return (*mmc)->ReadDiscInformation(mmc, buffer, length16, status, sense);

    case 0x52: // READ TRACK INFORMATION
        if (cdbLength < 10) return kIOReturnBadArgument;
        return (*mmc)->ReadTrackInformation(mmc, cdb[1] & 0x03, BKMMCReadUInt32(&cdb[2]),
                                            buffer, length16, status, sense);

    case 0x5A: // MODE SENSE (10)
        if (cdbLength < 10) return kIOReturnBadArgument;
        return (*mmc)->ModeSense10(mmc, (cdb[1] >> 4) & 0x01, (cdb[1] >> 3) & 0x01,
                                   (cdb[2] >> 6) & 0x03, cdb[2] & 0x3F,
                                   buffer, length16, status, sense);

    case 0x43: // READ TOC/PMA/ATIP
        if (cdbLength < 10) return kIOReturnBadArgument;
        return (*mmc)->ReadTableOfContents(mmc, (cdb[1] >> 1) & 0x01, cdb[2] & 0x0F, cdb[6],
                                           buffer, length16, status, sense);

    case 0x1B: { // START STOP UNIT, only for moving the tray
        if (cdbLength < 6 || (cdb[4] & 0x02) == 0) return BKMMC_ERROR_NEEDS_EXCLUSIVE_ACCESS;
        UInt8 tray = (cdb[4] & 0x01) ? kMMCDeviceTrayClosed : kMMCDeviceTrayOpen;
        IOReturn result = (*mmc)->SetTrayState(mmc, tray);
        *status = kSCSITaskStatus_GOOD;
        return result;
    }

    default:
        return BKMMC_ERROR_NEEDS_EXCLUSIVE_ACCESS;
    }
}

int32_t BKMMCDeviceExecute(BKMMCDevice *device,
                           const uint8_t *cdb,
                           uint8_t cdbLength,
                           void *buffer,
                           uint64_t bufferLength,
                           uint8_t direction,
                           uint32_t timeoutMS,
                           uint8_t *outTaskStatus,
                           uint8_t *outSense,
                           uint64_t *outTransferred) {
    if (device == NULL || cdb == NULL || cdbLength == 0) return kIOReturnBadArgument;

    SCSI_Sense_Data sense;
    memset(&sense, 0, sizeof(sense));
    SCSITaskStatus status = kSCSITaskStatus_No_Status;
    UInt64 transferred = 0;
    IOReturn result;

    if (!device->exclusive) {
        result = BKMMCExecuteShared(device, cdb, cdbLength, buffer, bufferLength, &status, &sense);
        if (result == kIOReturnSuccess && direction == BKMMC_DIRECTION_FROM_DEVICE) {
            transferred = bufferLength;
        }
    } else {
        SCSITaskInterface **task = (*device->task)->CreateSCSITask(device->task);
        if (task == NULL) return kIOReturnNoMemory;

        result = (*task)->SetCommandDescriptorBlock(task, (UInt8 *)cdb, cdbLength);
        if (result == kIOReturnSuccess) {
            if (direction != BKMMC_DIRECTION_NONE && buffer != NULL && bufferLength > 0) {
                SCSITaskSGElement range;
                range.address = (IOVirtualAddress)(uintptr_t)buffer;
                range.length = (IOByteCount)bufferLength;
                UInt8 transferDirection = (direction == BKMMC_DIRECTION_TO_DEVICE)
                    ? kSCSIDataTransfer_FromInitiatorToTarget
                    : kSCSIDataTransfer_FromTargetToInitiator;
                result = (*task)->SetScatterGatherEntries(task, &range, 1, bufferLength, transferDirection);
            } else {
                result = (*task)->SetScatterGatherEntries(task, NULL, 0, 0, kSCSIDataTransfer_NoDataTransfer);
            }
        }
        if (result == kIOReturnSuccess) {
            result = (*task)->SetTimeoutDuration(task, timeoutMS);
        }
        if (result == kIOReturnSuccess) {
            result = (*task)->ExecuteTaskSync(task, &sense, &status, &transferred);
        }
        (*task)->Release(task);
    }

    if (outTaskStatus != NULL) *outTaskStatus = (uint8_t)status;
    if (outSense != NULL) memcpy(outSense, &sense, BKMMC_SENSE_LENGTH);
    if (outTransferred != NULL) *outTransferred = transferred;
    return result;
}

#else

int BKMMCCopyDeviceIDs(uint64_t *ids, int maxCount) {
    (void)ids;
    (void)maxCount;
    return 0;
}

BKMMCDevice *BKMMCDeviceOpen(uint64_t registryID, int32_t *outError) {
    (void)registryID;
    if (outError != NULL) *outError = BKMMC_ERROR_UNSUPPORTED;
    return NULL;
}

void BKMMCDeviceClose(BKMMCDevice *device) { (void)device; }

int32_t BKMMCDeviceObtainExclusiveAccess(BKMMCDevice *device) {
    (void)device;
    return BKMMC_ERROR_UNSUPPORTED;
}

void BKMMCDeviceReleaseExclusiveAccess(BKMMCDevice *device) { (void)device; }

bool BKMMCDeviceHasExclusiveAccess(const BKMMCDevice *device) {
    (void)device;
    return false;
}

int32_t BKMMCDeviceExecute(BKMMCDevice *device, const uint8_t *cdb, uint8_t cdbLength,
                           void *buffer, uint64_t bufferLength, uint8_t direction, uint32_t timeoutMS,
                           uint8_t *outTaskStatus, uint8_t *outSense, uint64_t *outTransferred) {
    (void)device; (void)cdb; (void)cdbLength; (void)buffer; (void)bufferLength;
    (void)direction; (void)timeoutMS; (void)outTaskStatus; (void)outSense; (void)outTransferred;
    return BKMMC_ERROR_UNSUPPORTED;
}

#endif
