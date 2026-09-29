// A small C layer over IOKit's COM-style MMC and SCSI task interfaces,
// so Swift only deals with plain functions. Everything is macOS only.

#ifndef CIOKITMMC_H
#define CIOKITMMC_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returned by BKMMCDeviceExecute when a command can only be sent with exclusive access.
#define BKMMC_ERROR_NEEDS_EXCLUSIVE_ACCESS (-2)
/// Returned when the device interfaces could not be created.
#define BKMMC_ERROR_NO_INTERFACE (-3)
/// Returned on platforms without IOKit.
#define BKMMC_ERROR_UNSUPPORTED (-4)

/// Data direction for BKMMCDeviceExecute.
#define BKMMC_DIRECTION_NONE 0
#define BKMMC_DIRECTION_TO_DEVICE 1
#define BKMMC_DIRECTION_FROM_DEVICE 2

/// Length of the fixed-format sense data buffer.
#define BKMMC_SENSE_LENGTH 18

typedef struct BKMMCDevice BKMMCDevice;

/// Writes up to `maxCount` IORegistry entry IDs of CD, DVD and Blu-ray burners into `ids`.
/// Returns how many were found, which can be more than `maxCount`.
int BKMMCCopyDeviceIDs(uint64_t *ids, int maxCount);

/// Opens the burner with this IORegistry entry ID. Returns NULL on failure and sets `outError`.
BKMMCDevice *BKMMCDeviceOpen(uint64_t registryID, int32_t *outError);

/// Releases exclusive access if held, then closes the device.
void BKMMCDeviceClose(BKMMCDevice *device);

/// Takes exclusive access. Fails while a disc in the drive is mounted.
int32_t BKMMCDeviceObtainExclusiveAccess(BKMMCDevice *device);

/// Gives exclusive access back to macOS.
void BKMMCDeviceReleaseExclusiveAccess(BKMMCDevice *device);

bool BKMMCDeviceHasExclusiveAccess(const BKMMCDevice *device);

/// Sends one command. Without exclusive access only a few read-only commands are allowed
/// (TEST UNIT READY, INQUIRY, GET CONFIGURATION, READ DISC INFORMATION, READ TRACK INFORMATION,
/// MODE SENSE (10), READ TOC and tray open or close through START STOP UNIT); anything else
/// returns BKMMC_ERROR_NEEDS_EXCLUSIVE_ACCESS.
/// Returns an IOReturn value. 0 means the command was delivered; check `outTaskStatus` for its result.
int32_t BKMMCDeviceExecute(BKMMCDevice *device,
                           const uint8_t *cdb,
                           uint8_t cdbLength,
                           void *buffer,
                           uint64_t bufferLength,
                           uint8_t direction,
                           uint32_t timeoutMS,
                           uint8_t *outTaskStatus,
                           uint8_t *outSense,
                           uint64_t *outTransferred);

#ifdef __cplusplus
}
#endif

#endif
