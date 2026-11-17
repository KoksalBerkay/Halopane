# Adapter Ultra tracking protocol

These facts come from BLE captures of SpaceWalker running with a VITURE USB-C XR Charging Adapter Ultra. The advertised name was `R15_XXXXXX`; do not include the suffix when reporting an issue.

- GATT service `FFF0`; write requests go to `FFF2`, and `FFF1` carries responses and tracking notifications.
- Subscribe to `FFF1`, then send `0x0212` and `0x0211` with empty payloads, followed by `0x0015` with payload `01`. Pose notifications followed the last response. SpaceWalker also repeated `0x0015 01` during an active stream. The roles of the first two commands are unconfirmed.
- The observed values are 64 bytes. Commands start with `FF FE`; notifications with `FF FD`. Bytes 2–3 hold a little-endian CRC-16/XMODEM. Bytes 4–5 hold the little-endian length `L`; the CRC covers bytes 4 through `6 + L - 1`. The command ID is little-endian at bytes 14–15. Outgoing commands carry a little-endian timestamp consistent with Unix nanoseconds at bytes 6–13.
- Pose notification `0x0308` has `L = 44`. Bytes 10–13 advance as a millisecond counter. Bytes 18–29 contain three big-endian float32 angles in degrees. Bytes 30–33 were `01 00 00 00`; their meaning is unknown. Bytes 34–49 contain four big-endian floats `r0, r1, r2, r3`. The Hamilton quaternion in `(w, x, y, z)` order is `(-r2, -r3, r0, r1)`.
- The observed stream carries fused orientation at about 62.5 Hz. These captures do not establish raw IMU, position tracking or hand data over this interface.
