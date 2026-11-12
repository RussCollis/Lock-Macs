# Lock Macs

[![Buy me a coffee](https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=&slug=russcollis&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff)](https://www.buymeacoffee.com/russcollis)

<img src="Lock%20Macs/Assets.xcassets/AppIcon.appiconset/icon-mac-128@2x.png" width="128" alt="Lock Macs icon">

A SwiftUI app for sending a **Remote Lock** (MDM Device Lock) command to Macs managed by **Jamf Pro**. You can lock a single Mac by serial number or every member of a smart computer group. Each Mac gets its own random six-digit PIN.

## Features

- Target one Mac by **serial number**, or a whole **smart computer group**
- Creates a **random six-digit PIN per Mac** with a cryptographically secure generator
- Saves the PIN to a **computer extension attribute** in Jamf Pro *before* it sends the lock, so a PIN can't be lost
- Optional **lock screen message**, with a warning when the text is long
- Preview the Macs it found before locking. Macs that aren't MDM managed are flagged and skipped
- Shows the result for each Mac: whether the PIN was saved and whether the lock command was sent
- **Remove lock codes**: clears the stored PIN for a serial number or smart group once the Macs are unlocked
- Can **save the API details to the Keychain** (optional)

## Requirements

- macOS 27.2 or later (the project also builds for iOS and visionOS)
- Xcode 27 or later
- Jamf Pro with an **API Client** (Settings → API Roles and Clients)

### API role privileges

The API role for the client needs these privileges:

| Privilege |
| --- |
| Read Computers |
| Update Computers |
| Read Smart Computer Groups |
| Read Computer Extension Attributes |
| Update Computer Extension Attributes |
| Send Computer Remote Lock Command |

### Extension attribute

Create a computer extension attribute in Jamf Pro to hold the unlock PIN:

- **Data type:** String
- **Input type:** Text field

Write down its ID, which is the number at the end of the URL when you view it. You'll enter this ID in the app.

## Usage

1. Open `Lock Macs.xcodeproj` in Xcode, then build and run.
2. Enter your **Jamf Pro URL** (for example `https://yourorg.jamfcloud.com`), plus the **API Client ID** and **Client Secret**.
3. You can click **Save to Keychain** to store these details for next time.
4. Pick a target:
   - **Serial Number**: type the Mac's serial number.
   - **Smart Group**: click **Load Groups**, then choose a group.
5. Enter the **Extension Attribute ID** and, if you want, a **Lock Screen Message**.
6. Click **Find Macs** to check the target list and the extension attribute.
7. Click **Lock Mac(s)…** and confirm.

The results list shows each Mac's PIN. The PIN is also saved in the extension attribute in Jamf Pro.

> ⚠️ **Locked Macs restart and can only be unlocked with their PIN.** Try it on one test Mac before locking a group.

### Removing lock codes

After the Macs are unlocked, you can clear their stored PINs. Choose the same serial number or smart group and click **Find Macs**. Then click **Remove Lock Codes…** and confirm. This empties the extension attribute for each Mac it found, including Macs that aren't MDM managed. It doesn't send a command to the Macs.

## Credential storage

| Item | Where it's stored |
| --- | --- |
| Jamf Pro URL, Client ID | `UserDefaults`, plus the Keychain if you save there |
| Client Secret | Memory only, unless you click **Save to Keychain** |
| Extension Attribute ID, lock message | `UserDefaults` |

The Keychain item is a generic password named **"Lock Macs Jamf API"**, and it's only readable while the device is unlocked. Click **Remove from Keychain** to delete it. You can also delete it in Keychain Access.

The app invalidates the API access token after each operation.

## Jamf Pro API endpoints used

| Method | Endpoint | Purpose |
| --- | --- | --- |
| POST | `/api/oauth/token` | Get an access token |
| POST | `/api/v1/auth/invalidate-token` | Invalidate the token |
| GET | `/api/v4/computers-inventory` | Look up Macs |
| GET | `/JSSResource/computergroups` | List smart groups |
| GET | `/JSSResource/computergroups/id/{id}` | List group members |
| GET | `/api/v1/computer-extension-attributes/{id}` | Check the extension attribute |
| PATCH | `/api/v4/computers-inventory-detail/{id}` | Save the PIN |
| POST | `/api/v2/mdm/commands` | Send the Device Lock command |

## Project layout

| File | Purpose |
| --- | --- |
| `MyApp.swift` | App entry point |
| `ContentView.swift` | User interface |
| `LockController.swift` | App state and the lock workflow |
| `JamfClient.swift` | Jamf Pro API client |
| `KeychainStore.swift` | Keychain storage for the API details |

## Build number

The build number (`CFBundleVersion`) goes up by 1 on **every build**, and running or testing in Xcode both build first. The **Increment Build Number** build phase runs `Scripts/increment_build_number.sh`. That script stores the latest number in `BuildNumber.txt` and writes it into the built app. The side bar shows it as *Version 1.0 (build)*.

To start from a different number, put the number before it in `BuildNumber.txt`. For example, enter `99` and the next build is `100`.

## Engineer

Russell Collis

## License

Released under the [MIT License](LICENSE). Copyright © 2026 Russell Collis.
