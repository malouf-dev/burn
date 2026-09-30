// A small C layer over IOKit's COM-style MMC and SCSI task interfaces,
// so Swift only deals with plain functions. Everything is macOS only.

#ifndef CIOKITMMC_H
#define CIOKITMMC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returned by BKMMCDeviceExecute when a command can only be sent with exclusive access.
#define BKMMC_ERROR_NEEDS_EXCLUSIVE_ACCESS (-2)
/// Returned when the device interfaces could not be created.
#define BKMMC_ERROR_NO_INTERFACE (-3)
/// IOKit reported success but returned no plug-in.
#define BKMMC_ERROR_NO_PLUGIN (-5)
/// The plug-in didn't provide the requested interface.
#define BKMMC_ERROR_QUERY_FAILED (-6)
/// The SCSI task interface, which writing needs, isn't available for this drive.
#define BKMMC_ERROR_TASK_UNAVAILABLE (-7)
/// The command didn't complete: the transport or the drive failed before it returned a status.
/// `outTaskStatus` then holds IOKit's reason (task timeout, protocol timeout, not responding,
/// not present or delivery failure).
#define BKMMC_ERROR_SERVICE_FAILURE (-8)
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

/// Writes a plain-text report of each step of opening this device, for diagnosing drive problems.
void BKMMCDescribeDevice(uint64_t registryID, char *out, size_t length);

/// Releases exclusive access if held, then closes the device.
void BKMMCDeviceClose(BKMMCDevice *device);

/// Unmounts every volume on the disc in the drive through Disk Arbitration, so exclusive
/// access can be taken. Does nothing when no disc is present or nothing is mounted.
/// Returns 0 on success. Otherwise returns the Disk Arbitration status and writes its
/// explanation, when there is one, into `reason`.
int32_t BKMMCDeviceUnmountDisc(BKMMCDevice *device, char *reason, size_t reasonLength);

/// Writes the name and mount point of a mounted volume on the disc in the drive, through Disk
/// Arbitration, without sending the drive any commands. Returns false when nothing is mounted.
bool BKMMCDeviceCopyMountedVolume(BKMMCDevice *device, char *name, size_t nameLength, char *path, size_t pathLength);

/// Takes exclusive access. Fails while a disc in the drive is mounted.
int32_t BKMMCDeviceObtainExclusiveAccess(BKMMCDevice *device);

/// Gives exclusive access back to macOS.
void BKMMCDeviceReleaseExclusiveAccess(BKMMCDevice *device);

bool BKMMCDeviceHasExclusiveAccess(const BKMMCDevice *device);

/// Sends one command. Without exclusive access only a few read-only commands are allowed
/// (TEST UNIT READY, INQUIRY, GET CONFIGURATION, READ DISC INFORMATION, READ TRACK INFORMATION,
/// MODE SENSE (10), READ TOC and tray open or close through START STOP UNIT); anything else
/// returns BKMMC_ERROR_NEEDS_EXCLUSIVE_ACCESS.
/// Returns an IOReturn value or a BKMMC_ERROR code. 0 means the command completed; check
/// `outTaskStatus` for its result.
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
