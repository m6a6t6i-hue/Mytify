@echo off
setlocal
cd /d "%~dp0"
set CI=true
set BOT=true
set FLUTTER_SUPPRESS_ANALYTICS=true
set DART_SUPPRESS_ANALYTICS=true
call flutter pub get
if errorlevel 1 exit /b 1
call flutter analyze --no-pub
if errorlevel 1 exit /b 1
call flutter test --no-pub
if errorlevel 1 exit /b 1
call flutter build apk --release --target-platform android-arm64 --no-pub
if errorlevel 1 exit /b 1
cd android
call gradlew.bat --no-daemon -Ptarget-platform=android-arm64 :app:testReleaseUnitTest
if errorlevel 1 exit /b 1
endlocal
