# RamClean — Go-Live Checklist

What only you, the owner, can do before selling RamClean. The code, scripts and website are ready; each step below creates an account, a key or a setting that has to be yours.

RamClean is sold directly rather than on the Mac App Store, because App Store apps must be sandboxed and a sandboxed app can't quit other apps ([Apple DTS](https://developer.apple.com/forums/thread/768174)). See [SYSTEM-DESIGN.md](SYSTEM-DESIGN.md#selling-licensing-and-updates) for why it's built this way.

Every value you'll paste goes in one file, [`ProductConfig.swift`](../RamCleanCore/Sources/RamCleanCore/Licensing/ProductConfig.swift), except Sparkle's public key (in `project.yml`) and the website's own copy of the price and links (in `site/`). `./scripts/release.sh` refuses to build while any `REPLACE-ME` or a store ID of 0 is left in `ProductConfig.swift`.

## Checklist

- [ ] 1. Apple Developer Program and a Developer ID certificate
- [ ] 2. A notarytool keychain profile
- [ ] 3. Lemon Squeezy store and product; IDs pasted into `ProductConfig.swift`
- [ ] 4. Sparkle signing keys; public key pasted into `project.yml`
- [ ] 5. A domain, the website and the update feed hosted
- [ ] 6. A test release, end to end
- [ ] 7. (Optional) Setapp as a second channel

## 1. Apple Developer Program and a Developer ID certificate

1. Enrol at <https://developer.apple.com/programs/enroll/> with your Apple Account (two-factor authentication on). It costs **$99 a year**. Enrol as an individual, or as an organisation if you have a company (that needs a D-U-N-S number). Approval can take up to 48 hours.
2. In Xcode: **Settings → Accounts → +** and sign in with the same Apple Account.
3. Select your team, click **Manage Certificates…**, then **+ → Developer ID Application**. Only the account holder can create this one.
4. Check it's in your keychain:

   ```bash
   security find-identity -v -p codesigning
   ```

   You should see a line like `"Developer ID Application: Amal Mehta (ABCDE12345)"`. The 10 characters in brackets are your team ID.
5. Back it up: in Keychain Access, find the certificate under **My Certificates**, right-click → **Export…** as a `.p12` with a strong password, and keep it in your password manager. Without it you can't sign updates on another Mac.
6. Tell the release script which certificate to use (add it to `~/.zshrc` to keep it):

   ```bash
   export RAMCLEAN_SIGN_IDENTITY="Developer ID Application: Amal Mehta (ABCDE12345)"
   ```

## 2. A notarytool keychain profile

Notarization uploads each build to Apple, which scans it and issues a ticket so Gatekeeper opens it without a warning.

1. Make an app-specific password at <https://account.apple.com> → **Sign-In and Security → App-Specific Passwords**. Name it "notarytool".
2. Store it in your keychain under a profile name (it asks for the password):

   ```bash
   xcrun notarytool store-credentials RamCleanNotary --apple-id you@example.com --team-id ABCDE12345
   ```

3. Tell the release script the profile name:

   ```bash
   export RAMCLEAN_NOTARY_PROFILE=RamCleanNotary
   ```

## 3. Lemon Squeezy store and product

Lemon Squeezy is the merchant of record: it sells RamClean on your behalf, charges and pays out sales tax and VAT worldwide, handles refunds, and emails each buyer a licence key. It charges 5% + $0.50 per sale (Paddle charges the same and would also work, but the app's licence code talks to Lemon Squeezy's License API).

1. Sign up at <https://app.lemonsqueezy.com/register> and create a store. To take real payments, finish **Settings → Payouts** and the identity check Lemon Squeezy asks for; until then the store only works in test mode.
2. Turn on **Test mode** (toggle at the bottom left) to set everything up without real money.
3. **Products → + New Product**:
   - Name: RamClean. Description: copy from `site/index.html`.
   - Pricing: **Single payment**, **$5** (or whatever you choose; see "Changing the defaults" below).
   - Tax category: digital goods / software.
   - Files: optional. Buyers download the trial from your site and unlock it, so a file isn't needed.
   - **Generate license keys: on.** Activation limit: **3** (Macs per purchase; your choice). License length: **unlimited**.
   - Publish.
4. Copy three things:
   - **Store ID:** **Settings → Stores**; the number next to your store (e.g. `#12345`).
   - **Product ID:** open the product; it's the number in the page's address (`…/products/67890`), or in the product's **⋯** menu.
   - **Checkout link:** the product's **Share** button; it looks like `https://yourstore.lemonsqueezy.com/buy/1a2b3c4d-…`.
5. Paste them into [`ProductConfig.swift`](../RamCleanCore/Sources/RamCleanCore/Licensing/ProductConfig.swift): `lemonSqueezyStoreID`, `lemonSqueezyProductID` and `checkoutURL`. Paste the checkout link into `site/index.html` too (two "Buy" links).
6. Test: build (`./scripts/build.sh --run`), click **Buy** in Settings → Licence, pay with test card `4242 4242 4242 4242`, any future date and any CVC. Paste the key from the test receipt email into Settings → Licence → **Activate**. It should show **Licensed**. Then try **Deactivate on This Mac…**.
7. Going live: turn test mode off. Test-mode products are separate, so the live product has **its own product ID and checkout link**: copy them again (step 4) and paste the live values.

Nothing else is needed: the License API is public and needs no secret API key, so no secret ships in the app. The app refuses keys whose store or product ID doesn't match `ProductConfig`.

## 4. Sparkle signing keys

Sparkle checks that each update was signed with your private key before installing it.

1. Build once so Swift Package Manager downloads Sparkle:

   ```bash
   ./scripts/build.sh
   ```

2. Generate the key pair. The private key goes into your login keychain; the public key is printed:

   ```bash
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

3. Paste the printed public key into `project.yml` as `SUPublicEDKey: "…"` (it's empty now, which keeps updates switched off).
4. Back up the private key and keep it out of the repo:

   ```bash
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/Desktop/sparkle-private-key.txt
   ```

   Save that file's contents in your password manager, then delete the file. **If you lose the private key, people who already bought RamClean can't receive updates.**
5. Set `appcastURL` in `ProductConfig.swift` to where the feed will live: `https://yourdomain/updates/appcast.xml`.

## 5. Domain, website and update feed

The website is the plain HTML in `site/`; it needs no build step.

1. Buy a domain (e.g. at Cloudflare or Namecheap) and pick a static host. Cloudflare Pages and Netlify are free for this. The GitHub repo is private, so GitHub Pages would need a paid plan.
2. Fill in every `REPLACE-ME` in `site/` (search for it): the Buy links, the support email, the domain, the "last updated" dates and the governing law in the terms. Set `websiteURL` in `ProductConfig.swift`.
3. **Have a lawyer review `terms.html`, `refund.html` and `privacy.html`.** They're marked as templates. The refund page offers 30 days, no questions asked; match whatever you choose to your Lemon Squeezy settings.
4. Release a build (`./scripts/release.sh`, see below) and put its files into the site folder:

   ```bash
   mkdir -p site/updates site/download
   cp build/release/RamClean-1.0.dmg site/updates/
   cp build/release/RamClean-1.0.dmg site/download/RamClean.dmg   # the "Download the free trial" link
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast site/updates
   ```

   `generate_appcast` writes `site/updates/appcast.xml`, signed with the private key from your keychain. Both folders are in `.gitignore`, so the DMGs aren't committed.
5. Upload the `site/` folder, e.g. `npx wrangler pages deploy site --project-name ramclean` (Cloudflare) or drag it onto <https://app.netlify.com/drop>. Point your domain at it.
6. In Lemon Squeezy, set the store's website and support email, and the product's confirmation note (e.g. "Open RamClean → Settings → Licence and paste your key").

### Each new version

1. In `project.yml`, raise `CFBundleShortVersionString` (e.g. `"1.1"`) and **always** raise `CFBundleVersion` (`"2"`, `"3"`, …); Sparkle uses it to tell which build is newer.
2. `./scripts/release.sh`
3. Copy the new DMG into `site/updates/` (keep the old ones) and over `site/download/RamClean.dmg`, run `generate_appcast site/updates`, and upload `site/` again.

## 6. A test release, end to end

1. `./scripts/release.sh --check` lists anything missing, without building.
2. `./scripts/release.sh` builds, signs, notarizes (a few minutes each, twice: the app, then the DMG), staples, and writes `build/release/RamClean-<version>.dmg`.
3. Copy the DMG to another Mac, or another user account, and open it from a download (AirDrop or a browser, so it's quarantined). It should open with no warning beyond "downloaded from the internet".
4. Check: the trial shows 14 days; the Licence tab activates a live key; **Check for Updates…** finds nothing new. Then release a 1.0.1 and check that the 1.0 copy offers and installs it.

Under the hardened runtime, RamClean asks apps to quit with an Apple event. The entitlement is in `App/RamClean.entitlements`; if quitting from the released build ever fails, look in System Settings → Privacy & Security → Automation.

## 7. (Optional) Setapp as a second channel

Setapp is a Mac app subscription ($9.99+/month for users); developers are paid a share of revenue based on how much their app is used. It suits RamClean, since Setapp apps are not sandboxed.

1. Apply at <https://setapp.com/developers> and sign the developer agreement once accepted.
2. Setapp builds are separate: Setapp handles licensing and updates itself. Make a second target or build configuration that has bundle ID `com.amalmehta.RamClean-setapp`, leaves out Sparkle and the licence gate, and includes the Setapp framework (their docs explain both).
3. Upload that build in the Setapp developer portal and go through their review.

This needs code changes that aren't made yet; do it after direct sales work.

## Changing the defaults

All in [`ProductConfig.swift`](../RamCleanCore/Sources/RamCleanCore/Licensing/ProductConfig.swift):

| Setting | Default | Also change |
|---|---|---|
| `price` | `$5` | the Lemon Squeezy product price; `site/index.html` |
| `trialDays` | 14 | `site/index.html`, `site/terms.html`, `site/refund.html` |
| `offlineGraceDays` | 14 | `site/terms.html` |
| `recheckHours` | 24 (how often a licensed copy re-checks its key) | `site/privacy.html` if it's no longer "about once a day" |

What needs a licence after the trial is decided in `AppModel.allowed(_:)`'s callers: quitting and restarting apps, moving files to the Trash or off the Mac, and learning from Keep and Quit answers.

## Things to know

- **Development builds and the Keychain.** The trial clock and licence are kept in the Keychain. `./scripts/build.sh` signs ad hoc, so each rebuild looks like a new app to the Keychain and macOS may ask "RamClean wants to use confidential information". Click **Always Allow**. Released builds, signed with your Developer ID, don't ask.
- **Until step 3 is done, nothing locks.** With a store ID of 0, RamClean shows "Development copy" in Settings → Licence and every feature works, so your own copy never locks you out while you set up.
- **Your own copy.** Once the IDs are in, your Mac's trial counts from the first launch of a build with licensing in it. Use a test-mode key, or buy a copy.
