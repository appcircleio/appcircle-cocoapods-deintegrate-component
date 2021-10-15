# Appcircle Cocoapods Deintegrate

[Cocoapods](https://www.cocoapods.org) is a dependency manager for Swift and Objective-C applications. [Cocoapods](https://www.cocoapods.org) handles the installation of external libraries your application depends on during a build.

This component will remove all pods from your projects, as well as all traces and revert back the project settings overriden by CocoaPods. Podfile will remain as is. You can run CocoaPods install workflow step after this to re-install all dependencies.

## Removing Cocoapods and all traces from your project
This component will run `cocoapods deintegrate` on your repository folder.

Optional Input Variables
- `$AC_XCODEPROJ_PATH`: Specifies the xcodeproj file path with the name and extension of the file. Defaults to empty, meaning it will search the directory for .xcodeproj files. \
**Example values:** ./abc.xcodeproj
- `$AC_REPOSITORY_DIR`: Specifies the cloned repository directory.
- `$AC_COCOAPODS_VERSION`: Specifies cocoapods version.