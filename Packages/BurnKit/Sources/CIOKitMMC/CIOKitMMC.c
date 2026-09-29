#include "CIOKitMMC.h"

#include <stddef.h>

#if defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <stdio.h>
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

// Creates the IOKit plug-in for `service` and asks it for one interface.
// Returns 0 on success, or the failing step's error.
static int32_t BKMMCQueryInterface(io_service_t service, CFUUIDRef userClientType, CFUUIDRef interfaceID,
                                   void **outInterface) {
    *outInterface = NULL;
    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(service, userClientType, kIOCFPlugInInterfaceID,
                                                        &plugIn, &score);
    if (result != kIOReturnSuccess) return result;
    if (plugIn == NULL) return BKMMC_ERROR_NO_PLUGIN;
    HRESULT queryResult = (*plugIn)->QueryInterface(plugIn, CFUUIDGetUUIDBytes(interfaceID), outInterface);
    IODestroyPlugInInterface(plugIn);
    if (queryResult != S_OK || *outInterface == NULL) {
        *outInterface = NULL;
        return BKMMC_ERROR_QUERY_FAILED;
    }
    return 0;
}

BKMMCDevice *BKMMCDeviceOpen(uint64_t registryID, int32_t *outError) {
    if (outError != NULL) *outError = 0;

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID));
    if (service == IO_OBJECT_NULL) {
        if (outError != NULL) *outError = kIOReturnNotFound;
        return NULL;
    }

    // The MMC interface gives read-only status commands without exclusive access,
    // and hands out the SCSI task interface that writing needs.
    MMCDeviceInterface **mmc = NULL;
    int32_t mmcResult = BKMMCQueryInterface(service, kIOMMCDeviceUserClientTypeID, kIOMMCDeviceInterfaceID,
                                            (void **)&mmc);
    SCSITaskDeviceInterface **task = NULL;
    if (mmc != NULL) {
        task = (*mmc)->GetSCSITaskDeviceInterface(mmc);
    }
    // Fall back to asking for the SCSI task interface directly.
    int32_t taskResult = 0;
    if (task == NULL) {
        taskResult = BKMMCQueryInterface(service, kIOSCSITaskDeviceUserClientTypeID, kIOSCSITaskDeviceInterfaceID,
                                         (void **)&task);
    }
    IOObjectRelease(service);

    if (mmc == NULL && task == NULL) {
        if (outError != NULL) *outError = mmcResult != 0 ? mmcResult : taskResult;
        return NULL;
    }

    BKMMCDevice *device = calloc(1, sizeof(BKMMCDevice));
    if (device == NULL) {
        if (task != NULL) (*task)->Release(task);
        if (mmc != NULL) (*mmc)->Release(mmc);
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
    if (device->task != NULL) (*device->task)->Release(device->task);
    if (device->mmc != NULL) (*device->mmc)->Release(device->mmc);
    free(device);
}

static void BKMMCAppend(char *out, size_t length, const char *text) {
    if (out == NULL || length == 0) return;
    size_t used = strlen(out);
    if (used + 1 >= length) return;
    strncat(out, text, length - used - 1);
}

static void BKMMCAppendProperty(char *out, size_t length, io_registry_entry_t entry, const char *key) {
    CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, name, kCFAllocatorDefault, 0);
    CFRelease(name);
    char line[512];
    if (value == NULL) {
        snprintf(line, sizeof(line), "    %s: (none)\n", key);
    } else {
        CFStringRef description = CFCopyDescription(value);
        char text[400] = "";
        CFStringGetCString(description, text, sizeof(text), kCFStringEncodingUTF8);
        snprintf(line, sizeof(line), "    %s: %s\n", key, text);
        CFRelease(description);
        CFRelease(value);
    }
    BKMMCAppend(out, length, line);
}

void BKMMCDescribeDevice(uint64_t registryID, char *out, size_t length) {
    if (out == NULL || length == 0) return;
    out[0] = 0;
    char line[512];

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID));
    if (service == IO_OBJECT_NULL) {
        BKMMCAppend(out, length, "Service not found in the IORegistry.\n");
        return;
    }

    // The matched service and its parents.
    io_registry_entry_t entry = service;
    IOObjectRetain(entry);
    for (int level = 0; level < 6 && entry != IO_OBJECT_NULL; level++) {
        io_name_t className;
        IOObjectGetClass(entry, className);
        snprintf(line, sizeof(line), "%s%s\n", level == 0 ? "Matched: " : "Parent:  ", className);
        BKMMCAppend(out, length, line);
        if (level == 0) {
            BKMMCAppendProperty(out, length, entry, kIOPropertySCSITaskDeviceCategory);
            BKMMCAppendProperty(out, length, entry, "IOCFPlugInTypes");
            BKMMCAppendProperty(out, length, entry, "IOUserClientClass");
        }
        io_registry_entry_t parent = IO_OBJECT_NULL;
        kern_return_t kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent);
        IOObjectRelease(entry);
        entry = (kr == KERN_SUCCESS) ? parent : IO_OBJECT_NULL;
    }
    if (entry != IO_OBJECT_NULL) IOObjectRelease(entry);

    // Each step of opening the device.
    MMCDeviceInterface **mmc = NULL;
    int32_t result = BKMMCQueryInterface(service, kIOMMCDeviceUserClientTypeID, kIOMMCDeviceInterfaceID, (void **)&mmc);
    snprintf(line, sizeof(line), "MMC interface: %s (0x%08X)\n", result == 0 ? "ok" : "failed", (uint32_t)result);
    BKMMCAppend(out, length, line);
    if (mmc != NULL) {
        SCSITaskDeviceInterface **task = (*mmc)->GetSCSITaskDeviceInterface(mmc);
        snprintf(line, sizeof(line), "SCSI task interface from MMC: %s\n", task != NULL ? "ok" : "none");
        BKMMCAppend(out, length, line);
        SCSITaskStatus status = kSCSITaskStatus_No_Status;
        SCSI_Sense_Data sense;
        memset(&sense, 0, sizeof(sense));
        IOReturn tur = (*mmc)->TestUnitReady(mmc, &status, &sense);
        snprintf(line, sizeof(line), "TEST UNIT READY: 0x%08X, status 0x%02X, sense key 0x%X ASC 0x%02X ASCQ 0x%02X\n",
                 (uint32_t)tur, (unsigned)status, sense.SENSE_KEY & 0x0F,
                 sense.ADDITIONAL_SENSE_CODE, sense.ADDITIONAL_SENSE_CODE_QUALIFIER);
        BKMMCAppend(out, length, line);
        if (task != NULL) (*task)->Release(task);
        (*mmc)->Release(mmc);
    }

    SCSITaskDeviceInterface **direct = NULL;
    result = BKMMCQueryInterface(service, kIOSCSITaskDeviceUserClientTypeID, kIOSCSITaskDeviceInterfaceID,
                                 (void **)&direct);
    snprintf(line, sizeof(line), "SCSI task interface directly: %s (0x%08X)\n", result == 0 ? "ok" : "failed",
             (uint32_t)result);
    BKMMCAppend(out, length, line);
    if (direct != NULL) (*direct)->Release(direct);

    IOObjectRelease(service);
}

int32_t BKMMCDeviceObtainExclusiveAccess(BKMMCDevice *device) {
    if (device == NULL) return kIOReturnBadArgument;
    if (device->exclusive) return kIOReturnSuccess;
    if (device->task == NULL) return BKMMC_ERROR_TASK_UNAVAILABLE;
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
    if (mmc == NULL) return BKMMC_ERROR_NEEDS_EXCLUSIVE_ACCESS;
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

void BKMMCDescribeDevice(uint64_t registryID, char *out, size_t length) {
    (void)registryID;
    if (out != NULL && length > 0) out[0] = 0;
}

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
