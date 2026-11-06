# Data safety form: suggested answers

A draft for Play Console → Policy → App content → Data safety, based on what the code does. You submit the form and are responsible for it, so check each answer. Google publishes guidance on what its Navigation SDK collects, for this form: search the Navigation SDK documentation for "Google Play data safety" and add what it lists.

## Overview questions

| Question | Answer | Why |
| --- | --- | --- |
| Does your app collect or share any of the required user data types? | Yes | Location and searches go to Google, Open-Meteo and the charging networks. |
| Is all of the user data collected by your app encrypted in transit? | Yes | Every service is called over HTTPS. |
| Do you provide a way for users to request that their data is deleted? | No account data is held | The app has no servers or accounts. On-device data goes when the app is uninstalled or its data is cleared. |

## Data types

### Location → Precise location

- Collected: Yes
- Shared: Yes. Google's Navigation SDK uses navigation data for its own purposes (improving Google Maps), which counts as sharing.
- Processed ephemerally: No, for Google. Yes, for Open-Meteo and the charging networks, which only answer each request.
- Required or optional: Required. Navigation can't work without it.
- Purposes: App functionality. For the Google share, also follow Google's SDK guidance above.

### Location → Approximate location

- Same answers as precise location. The app asks for both, as Android requires.

### App activity → In-app search history

- Collected: Yes. Destination searches go to Google Places.
- Shared: No, beyond the service provider handling the request.
- Processed ephemerally: Yes, as far as the app is concerned. Nothing is stored by the developer.
- Required: Yes, to find a destination.
- Purposes: App functionality.

### Everything else

Personal info, financial info, health, messages, photos, audio, files, calendar, contacts, web browsing and device IDs: not collected by the app's own code. Check Google's SDK guidance for anything the Navigation SDK adds, such as diagnostics.

## Not collected

- Car details (battery, consumption, range, drag coefficient) stay on the device.
- No analytics, advertising or crash-reporting SDKs are included.
