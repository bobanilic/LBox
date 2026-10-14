<div align="center">
   <img width="217" height="217" src="./screenshots/lbox_icon.jpg" alt="Logo">
</div>

<div align="center">
  <h1><b>LBox</b></h1>
  <p><i>A native iOS repository manager and downloader offering seamless integration with LiveContainer. Browse public sources, download IPAs, and install/launch apps directly on your device.</i></p>
</div>

---

> **⚡ Quick Start**: To enable automatic app installation to LiveContainer, select its directory ("On My iPhone" > "LiveContainer") on your device (see **[Fix File Picker](#fix-file-picker)** if unable). Then, enable **"Auto .ipa to .app"** in LBox Settings.

## 📥 Download

**[Download Latest IPA (IOS 17.6+)](https://github.com/Lolendor/LBox/releases/download/v1.2/LBox.ipa)**

## 🚀 Overview

**LBox** bridges the gap between finding apps and running them on iOS. Instead of manually searching for IPA files and moving them around the file system, LBox allows you to add repositories (similar to AltStore or ESign), download apps in the background, and automatically extract them into your LiveContainer storage.

## 📱 Screenshots

| Store View | App Details | Downloads | Installed Apps |
|:---:|:---:|:---:|:---:|
| <img src="./screenshots/store.png" width="200" alt="Store View"/> | <img src="./screenshots/app_details.png" width="200" alt="App Details"/> | <img src="./screenshots/downloads.png" width="200" alt="Downloads"/> | <img src="./screenshots/apps.png" width="200" alt="Apps"/> |

## ✨ Key Features

*   **Repository Management**:
    *   Add and manage unlimited public repositories (JSON format).
    *   **Remote Folders (Repo Lists)**: Subscribe to a single URL (text file) to automatically fetch and maintain a list of multiple repositories.
    *   Organize sources into folders.
    *   Import/Export repository lists via JSON or Clipboard.
*   **App Management & Updates**:
    *   **Update Detection**: Automatically compares installed apps with repository versions and notifies you of available updates.
    *   **Smart Updates**: Update installed apps directly while **preserving user data** and configurations.
    *   Auto-detects apps installed within the LiveContainer folder.
    *   **One-tap Launch**: Open apps directly from LBox using the `livecontainer://` URL scheme.
    *   **Auto-Install**: Automatically unzips and moves downloaded `.ipa` files to the specific LiveContainer application directory.
*   **Download Manager**:
    *   Robust background downloading with pause/resume support.
    *   Direct download via URL (for IPAs hosted outside user repositories).
    *   Visual progress tracking and local file management.
*   **Version History**:
    *   View and download specific versions of an app (downgrade/upgrade support).
*   **Customization**:
    *   Configure custom storage locations for Downloads and LiveContainer apps (using Security Scoped Bookmarks).
    *   Search, filter, and sort apps by name, date, or size.

## 🛠 How it Works

### Fork reliability update (1.3.3)

Downloads now use a persistent URL-to-file index so equal filenames from different sources cannot collide. Files downloaded by older builds remain in the Downloads list for manual extraction or sharing; they are not guessed to belong to a particular source URL.

Failed updates retain their recovery backup and source IPA. Replacement failures roll back the installed bundle, and metadata changes are written atomically and verified before temporary containers are removed. Deleting a recovery backup does not delete user data.

Repository refreshes support mixed legacy/AltStore feeds and recalculate updates even when the app count is unchanged. ShrubLibrary discovery validates feeds, uses up to six parallel requests, caches its catalog for six hours, and retains the last known catalog on failure.

### Native interface redesign (1.4.0)

The four main tabs are Browse, Apps, Downloads, and Sources. The toolbar gear opens the complete Settings screen. Automatic, light, and dark appearances use system colors and native navigation controls.

Browse keeps source filtering, search, name/date/size sorting, and list/3/4/5-column layouts. An existing layout preference is retained; List is the default for a fresh installation. App details keep screenshots, descriptions, bundle identifiers, all available versions, downloads, and IPA sharing.

Apps shows installed versions, Open/Update buttons, and Update All. The options menu retains source details, installed/latest IPA downloads, sharing, URL copying, bundle-ID searching, and app deletion. Update All downloads available updates through the existing installation and recovery workflow; automatic installation still follows the Auto .ipa to .app setting.

Downloads separates active transfers from failures and keeps pause/resume/retry/cancel, URL downloads, file import, rename, sharing, extraction, deletion, and clearing files. Preparing an app disables duplicate transfer actions. Sources retains folders, remote lists, all switches, editing, moving, copying, import/export, and error details.

All existing preference/bookmark keys and repository caches are unchanged. Existing Settings controls remain: both storage directories and their Default actions, Auto .ipa to .app, Strict Grouping, repository sorting, Manage Sources, every repository export mode, JSON import, reset, and debug logs in debug builds. Appearance, catalog layout, and app sorting are now also accessible in Settings.

### History and guest launch correction (1.4.1)

Hybrid feeds now retain both their legacy current-version record and all published `versions[]` entries. Search presents the newest listing for each app/source; app details show available versions across enabled sources, regardless of catalog grouping. A one-time source refresh rebuilds caches that older parsers reduced to a single version. History can only include versions and download URLs actually published by the sources.

The Browse spotlight selects Delta, or LiveContainer if Delta is unavailable, from the enabled catalog and stays independent of name/date/size sorting. It is hidden when searching or filtering a specific source.

Updates carry over verified container/settings metadata from the recovery backup before replacing a bundle. Old patch/signing caches are removed and the new executable is marked for LiveContainer preparation. Recovery finalization preserves fresh signing state. The corresponding LiveContainer Siri Router update detects this preparation state (and missing metadata), hands off to its UI, patches/signs through the existing workflow, and continues to the queued app. The target container and any media/deep-link payload are retained. Install the matching LiveContainer launch fix before using this update workflow.

### Quick checks

On macOS with Xcode installed, run `bash tests/run-quick-checks.sh`. These offline checks exercise production decoding, download state transitions, HTTP validation, file identity, and injected update/rollback failures. They also run before the existing GitHub IPA build.

Device checks: pause/resume an IPA; lock the phone during a download and reopen LBox; install a larger IPA while scrolling; update an existing LiveContainer app and confirm its data survives; refresh a repository containing a newer version without adding apps; add ShrubLibrary and refresh again.

### Source compatibility correction (1.3.4)

Repository loading keeps the previous version's normal cache behavior, accepts valid JSON delivered through a plain `URLResponse`, and treats HTTP 304 as an unchanged catalog. Binary IPA downloads retain their separate strict response checks. Optional metadata differences or a single malformed app no longer reject an otherwise usable feed. Sources show their actual fetch/format error below the name, retain saved apps after a failed refresh, and provide Retry Source / Copy Error Details actions. Short regression checks include current SideStore Team Picks and AltGallery feed fixtures.

1.  **Initial Setup**: Upon first launch, LBox will ask for the LiveContainer directory. Select the root folder of your installed LiveContainer app. This step is required for auto-installation and launching apps.
2.  **Add a Source**: Input a URL to a compliant app repository JSON **or** add a "Folder" utilizing a list URL to batch-import repos.
3.  **Browse & Download**: Find the app you want and tap "Get". LBox handles the download in the background.
4.  **Install/Update**: 
    *   **New Install**: LBox extracts the `.ipa` to your Applications folder.
    *   **Update**: If the app exists, LBox offers to update it while keeping your documents and settings intact.
5.  **Launch**: Navigate to the "Apps" tab and tap the app to run it instantly via LiveContainer.

## ⚙️ Build Instructions

### Prerequisites
*   Mac with Xcode installed.
*   An iOS device (Simulators may not fully support LiveContainer integration).
*   [LiveContainer](https://github.com/khanhduytran0/LiveContainer) installed on the target device.

### Installation
1.  Clone the repository:
    ```bash
    git clone https://github.com/yourusername/LBox.git
    ```
2.  Open LBox.xcodeproj in Xcode.
3.  Select your Development Team in the "Signing & Capabilities" tab.
4.  Build and run on your device.

## ⚠️ Known Issues

*   **"App bundle not found! Unable to read LCAppInfo.plist" Error**:
    You may encounter this error popup immediately after installing an app and trying to launch it for the first time.
    *   **Solution**: Simply dismiss the error and tap the **Run** button again. The app should launch successfully, and this error will not appear on subsequent launches.

*   <a id="fix-file-picker"></a>**Unable to select LiveContainer Directory**:
    If the file picker does not appear or you cannot select a folder during the initial setup:
    *   **Solution**: Open LiveContainer, find **LBox** in the "My Apps" list, press and hold the icon, tap **Settings**, and enable **Fix File Picker**. Then try selecting the directory again.
    <img src="./screenshots/how_to_fix_file_picker.png" width="300" alt="Fix File Picker Settings">

## 📂 File Structure

*   AppData.swift: Handles repository parsing, app models, and data persistence.
*   DownloadManager.swift: Manages URLSession tasks, file system operations, and zip extraction.
*   ContentView.swift: The main navigation and UI entry point.
*   AppDetailView.swift: Displays detailed app information, screenshots, and version history.

## credits

* Developed by Lolendor.
* Designed to work with LiveContainer.

## Support the project

If you find this project useful:

- **TON / USDT (TON)**  `UQAyBchGEKi9NnNQ3AKMQMuO-SGEhMIAKFAbkwwrsiOPj9Gy`

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

