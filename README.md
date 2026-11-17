# Family Safe: easy install (no Flutter, no Android Studio)

You do three things: make a free database, let GitHub build the app, install it on both phones.

## 1. Free database (5 minutes, works in a phone browser)
1. Go to console.firebase.google.com, sign in with Google, tap "Create a project". Skip Analytics.
2. Open Build > Firestore Database > Create database > "Production mode" > any location.
3. Open the Rules tab, replace everything with the text below, tap Publish:

       rules_version = '2';
       service cloud.firestore { match /databases/{db}/documents {
         match /families/{code} { allow get, create, update: if true; allow list, delete: if false; }
       } }

4. Open Project settings (gear icon). Copy the "Project ID" (lowercase, like family-safe-1a2b3).

## 2. Build the app on GitHub (10 minutes, nothing to install)
1. Sign up at github.com, tap New repository, name it family-safe, make it Public, Create.
2. Tap "uploading an existing file". Unzip this package, then drag in EVERYTHING inside the
   folder: lib, pubspec.yaml and the hidden .github folder
   (on Mac press Cmd+Shift+. to show hidden files). Tap Commit changes.
   If .github did not upload: Add file > Create new file, type the name
   `.github/workflows/build.yml`, and paste in the contents of that file.
3. Open the Actions tab. Wait about 8 minutes for the green tick.
4. Open Releases (right side of the repo page). Tap the newest build and download `app-release.apk`.

## 3. Install and pair
1. Open the repo's Releases page on each phone and download the APK. Tap it to install and
   allow "install from this source". If Play Protect warns, choose "Install anyway".
2. Parent's phone: open the app, type your Project ID, tap "Set up parent's phone".
   Tap the copy icon to copy the pairing code and send it to your child (WhatsApp is fine).
3. Child's phone: paste the code, tap "Set up child's phone", allow Location and Notifications.
   Then Settings > Apps > Family Safe > Battery > Unrestricted.

The pairing code is the only key to your child's location. Share it only with your child.
