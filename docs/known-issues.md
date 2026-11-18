# Known issues

Halopane has been tested on one setup: VITURE Luma Ultra, VITURE USB-C XR Charging Adapter Ultra and an iPhone 16 Pro Max.

## Tracking

- **Panels sometimes start tilted or drift right after launch.** Try **Recenter**. If tracking stays paused, try **More → Restart tracking**. If neither helps, close and reopen the app.

## Video and media

- **YouTube 360° videos do not work.** YouTube refuses 360° playback in the browser Halopane uses. Spatial Player has separate View settings for local 180° and 360° files.
- **Panoramic playback needs more device testing.** Flat playback of spatial photos and videos has been tested. If a panoramic file looks wrong, try a different View or Layout in the player.
- **Protected video depends on the service.** Video protected with Apple FairPlay plays (tested with Pluto TV and Plex). Services that only offer Widevine or PlayReady cannot play in any iPhone browser. Netflix, HBO Max and other subscription services have not been tested yet. If one refuses to play, see [Streaming services](guide.md#streaming-services).

## 2D-to-3D

- **New and needs device testing.** If 3D does not appear, or only one eye shows the video, attach the report from **Settings → Troubleshooting → Share report**. It includes a "2D to 3D" line with what happened.
- **Protected video stays 2D.** FairPlay video, as on Netflix or Disney+, can't be read by apps, so its depth can't be estimated.
- **Depth is estimated, not measured.** Scenes with people, landscapes and objects work best. Text, cartoons and on-screen graphics can look flat or slightly bent. Lower **Depth** if something looks wrong.
- **Edges of near objects stretch slightly.** Halopane moves the picture instead of inventing the hidden background, so a thin stretched band can appear beside close objects. Lower **Depth** to make it smaller.
- **The first start takes a few seconds** while the system prepares the depth model for this iPhone.

## Cloud gaming

- **GeForce NOW:** scrolling near the top of the game catalogue can be slow.
- **Amazon Luna:** not verified.

## Websites

- **Sign-in:** some sites need you to sign in on the phone screen. Halopane offers this when it detects it.
- **Embedded players** and third-party sign-in windows vary from site to site.
- **Office documents:** previews can change the layout. Use a PDF export when layout matters.

## Reporting a problem

Open an issue using the bug template. Attach the report from **Settings → Troubleshooting → Share report**. It leaves out the sites you visit, apart from well-known services such as YouTube or Netflix.
