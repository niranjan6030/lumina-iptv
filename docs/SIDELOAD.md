# Install Lumina on your iPhone for free (no paid Apple account)

iOS can't install apps straight from a GitHub repo. But a free Apple ID is enough to put your own app on your own
iPhone ("sideloading"). The cloud builds an **unsigned `Lumina.ipa`**; a free sideloading tool signs it with your Apple ID.

## The deal (free vs paid)
| | Free Apple ID | Paid ($99/yr) |
|---|---|---|
| Live TV, movies, series, search, PiP, background audio, AirPlay | yes | yes |
| App expires | **every 7 days** (re-sign; AltStore can do it automatically) | 90 days via TestFlight |
| Active sideloaded apps | max 3 | unlimited |
| **CarPlay in the car** | **no** (Apple only grants it to paid, approved accounts; there is no free workaround) | yes, after Apple approves |

Android Auto has no such restriction (see the main README), if you ever use an Android phone.

## Get the file
The latest build is already on your Mac: `~/Lumina/Lumina-IPA/Lumina.ipa`. For a fresh build after code changes:
```bash
cd ~/Lumina/Lumina && ./scripts/get-ipa.sh
```

## Option A: Sideloadly (simplest, USB cable)
1. Download **Sideloadly** (free, macOS) from <https://sideloadly.io> and install it.
2. iPhone: **Settings → Privacy & Security → Developer Mode → On**, then let it restart.
3. Plug the iPhone into the Mac with a cable and tap **Trust**.
4. Drag `Lumina.ipa` into Sideloadly, enter your Apple ID, click **Start**. Approve the two-factor prompt.
5. iPhone: **Settings → General → VPN & Device Management →** your Apple ID **→ Trust**.
6. Open Lumina. After 7 days it stops opening; repeat step 4 to renew (your sources and favorites are kept).

## Option B: AltStore (refreshes itself over Wi-Fi)
1. Install **AltServer** on the Mac from <https://altstore.io>, with the iPhone connected once by cable, and use it to install AltStore on the iPhone.
2. Enable Developer Mode (step 2 above) and trust the profile (step 5 above).
3. Send `Lumina.ipa` to the iPhone (AirDrop or Files), open it **in AltStore** → it installs.
4. Keep AltServer running on the Mac on the same Wi-Fi; AltStore renews the app in the background before the 7 days run out.

## Things to know
* **Your Apple ID goes only into the sideloading tool**, never to me or GitHub. Many people use a spare Apple ID for this.
* These are third-party tools, not made by Apple; Apple can change what free accounts allow at any time.
* Free accounts can create only a few App IDs per week, so don't reinstall repeatedly.
* If the tool says the Bundle ID is taken, it will rename it automatically (Sideloadly) or you can change `LUMINA_BUNDLE_ID` in `Config/Signing.xcconfig` and rebuild.
