# Install Lumina on your iPhone via TestFlight (no Xcode on your Mac)

GitHub's cloud Mac builds, signs and uploads the app. You install it from the TestFlight app on your iPhone.
You never open Xcode.

## What you need
* A **paid Apple Developer Program** membership (US$99/year): <https://developer.apple.com/programs/enroll/>. Approval can take up to 2 days.
* Your Mac only needs Terminal (`gh` is already set up and logged in).

## One-time setup (about 20 minutes)

### 1. Find your Team ID
<https://developer.apple.com/account> → **Membership details** → copy **Team ID** (10 characters, like `AB12CD34EF`).

### 2. Register your app's Bundle ID
Pick a Bundle ID that is unique to you, e.g. `com.niranjan.lumina` (must not be taken by anyone else).
<https://developer.apple.com/account/resources/identifiers/list> → **+** → **App IDs** → **App** → Description `Lumina`,
Bundle ID **Explicit** = your value → Continue → Register. (No capabilities needed yet.)

### 3. Create the app in App Store Connect
<https://appstoreconnect.apple.com/apps> → **+** → **New App**
* Platforms: iOS
* Name: must be unique across the App Store, e.g. `Lumina Player 6030` (the name on your home screen stays "Lumina")
* Primary language: your choice
* Bundle ID: choose the one from step 2
* SKU: anything, e.g. `lumina-001`

### 4. Create an API key (this is what lets the cloud sign and upload for you)
<https://appstoreconnect.apple.com/access/integrations/api> → **Team Keys** → **+**
* Name: `GitHub CI`
* Access: **Admin** (needed so Xcode can create the signing certificate for you the first time; you can delete the key afterwards)
* **Download the `.p8` file now. Apple only lets you download it once.** Save it in `~/Downloads`.
* Note the **Key ID** (next to the key) and the **Issuer ID** (top of the page, a long UUID).

### 5. Give GitHub the credentials
Run these in Terminal, replacing the capitalised parts. The key file goes straight from disk into GitHub's encrypted
secrets; don't paste it anywhere else.

```bash
cd ~/Lumina/Lumina
gh secret set ASC_KEY_ID --body "YOUR_KEY_ID"
gh secret set ASC_ISSUER_ID --body "YOUR_ISSUER_ID"
base64 -i ~/Downloads/AuthKey_YOUR_KEY_ID.p8 | gh secret set ASC_KEY_BASE64
gh variable set APPLE_TEAM_ID --body "YOUR_TEAM_ID"
gh variable set BUNDLE_ID --body "com.niranjan.lumina"
```

### 6. Build and upload
```bash
gh workflow run "iOS TestFlight"
gh run watch
```
Takes about 10 minutes. Afterwards the build shows up in App Store Connect → your app → **TestFlight** after Apple's
processing (usually 10–30 minutes; you also get an email).

### 7. Install on your iPhone
1. Install **TestFlight** from the App Store on your iPhone and sign in with your Apple ID.
2. App Store Connect → your app → **TestFlight** → **Internal Testing** → **+** → create a group → add yourself (your Apple ID).
3. Open TestFlight on the iPhone → **Lumina** → **Install**.

Internal testers don't need Apple's beta review, so you can install the first build as soon as processing finishes.
Builds last 90 days; run step 6 again to refresh or ship updates (each run gets a new build number automatically).

## CarPlay on the real car
CarPlay needs Apple's approval for your account. Request it at <https://developer.apple.com/contact/carplay/>
(wording suggestion is in the main README). The app installs and works fine on the phone without it.
When Apple approves:
```bash
gh variable set CARPLAY_ENTITLEMENT --body "true"
gh workflow run "iOS TestFlight"
```
If the build then complains about the entitlement, open the App ID in the developer portal and make sure the CarPlay
capability shows as enabled; then run again.

## If something fails
| Message in the run log | Meaning / fix |
|---|---|
| `TestFlight upload skipped … Missing: …` | A secret or variable from step 5 isn't set. The run still did an unsigned build. |
| `No profiles for '…' were found` / `provisioning profile … doesn't include` | Bundle ID in step 2 and the `BUNDLE_ID` variable differ, or the key isn't **Admin**. |
| `Cloud signing permission error` / `forbidden` | Recreate the API key with **Admin** access. |
| `The bundle version must be higher` | Re-run; the build number grows with every run. |
| `No suitable application records were found` | Step 3 wasn't done, or the Bundle ID doesn't match the app record. |
| `Invalid Provisioning Profile … CarPlay` | `CARPLAY_ENTITLEMENT=true` set before Apple approved it. Delete the variable. |

## Housekeeping
* The key lives only in GitHub's encrypted secrets (never in the code). Only people with write access to the repo can run the workflow. Delete the API key in App Store Connect when you're done.
* macOS minutes in private repos are billed at 10× on GitHub's free tier (~200 real minutes/month), roughly 15–20 uploads per month.
