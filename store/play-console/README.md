# Play Console assets

Everything for the Vinfast Copilot store listing. Rebuild the icons, feature graphic and captioned screenshots with `python3 tool/make_store_assets.py` from the project root.

| File | Where it goes in Play Console | Spec |
| --- | --- | --- |
| `icon/app-icon-512.png` | Store presence → Main store listing → App icon | 512 × 512 PNG, as Play requires |
| `icon/app-icon-1024.png` | Spare, for websites or press | 1024 × 1024 PNG |
| `feature-graphic/feature-graphic-1024x500.png` | Main store listing → Feature graphic | 1024 × 500 PNG, no transparency |
| `screenshots/phone/captioned/*.png` | Main store listing → Phone screenshots (use these) | 6 × 1080 × 1920, 9:16 |
| `screenshots/phone/raw/*.png` | Same, if you'd rather have plain screenshots | 6 × 1080 × 1920 |
| `listing/store-listing.md` | Main store listing text: name, short and full description | Within Play's length limits |
| `listing/privacy-policy.html` | Host it, then put the link in App content → Privacy policy | Fill in the date and support email |
| `listing/data-safety.md` | App content → Data safety | Suggested answers to check |
| `video/foreground-service-location-walkthrough.mp4` | Upload to YouTube (unlisted is fine), then paste the link in App content → Foreground service permissions → Location | 2 min 15 s, 720 × 1774, captioned |

The screenshots come from the real app on the Android emulator, with real routes, chargers and live status, on a 1080 × 1920 screen. Play allows at most a 2:1 aspect ratio, so the default 20:9 phone shape won't do.

The launcher icons in the app were replaced with the same logo: Android adaptive and legacy icons in `android/app/src/main/res/mipmap-*`, and the iOS set in `ios/Runner/Assets.xcassets/AppIcon.appiconset`.

## Not covered by these files

- **Tablet screenshots** are optional. Without them the listing shows the phone screenshots on tablets.
- **Android Auto screenshots** are needed if you opt in to Android Auto under Advanced settings → Form factors. Capture them with Google's Desktop Head Unit. The car screen then also goes through Google's quality review.
- **A promo video** is optional.

## Before you submit

1. **The name.** "Vinfast" in the app name and listing may be flagged under Play's impersonation and intellectual property policies unless VinFast has given permission. The description says the app is independent, but that may not be enough. A neutral name is safest.
2. **Release signing.** `android/app/build.gradle.kts` signs release builds with the debug key, which Play rejects. Create an upload key, add a release signing config, and use Play App Signing.
3. **Build the bundle** without the simulation flags: `flutter build appbundle --release --dart-define-from-file=config/keys.json`. Bump `version` in `pubspec.yaml` for each upload.
4. **Foreground service declaration.** The app declares a location foreground service, so App content → Foreground service permissions asks why it's needed and for a video. Use `video/foreground-service-location-walkthrough.mp4`. Suggested description: "Turn-by-turn navigation uses the device's location continuously while the user drives, including when the screen is off or another app is in front. The service starts when the user taps Start, shows an ongoing notification with the next turn, and stops when the user ends navigation or arrives." 
5. **Privacy policy URL.** Host `listing/privacy-policy.html` somewhere public, such as GitHub Pages or your own site.
6. **Content rating questionnaire.** No user content, chat or purchases. Expect a rating for everyone.
7. **Target audience.** 18 and over suits a driving app and keeps it out of the Families requirements.
8. **Third-party services.** The Statiq and chargeindia.com endpoints are undocumented, so get their permission before a public release. Open-Meteo's free tier is for non-commercial use only.
9. **The API key.** It's built into the app and can be pulled out of it. Keep it restricted to the APIs the app uses, and set quota limits and a budget alert in Google Cloud.
