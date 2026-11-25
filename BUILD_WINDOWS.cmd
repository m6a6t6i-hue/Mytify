@echo off
setlocal
cd /d "%~dp0"
set CI=true
set BOT=true
set FLUTTER_SUPPRESS_ANALYTICS=true
set DART_SUPPRESS_ANALYTICS=true
where flutter >nul 2>&1
if errorlevel 1 goto tools
where cargo >nul 2>&1
if errorlevel 1 goto tools
where rc.exe >nul 2>&1
if errorlevel 1 goto tools
where cmake >nul 2>&1
if errorlevel 1 goto tools
where npm >nul 2>&1
if errorlevel 1 goto tools
pushd tools\web_bridge
call npm ci --ignore-scripts
if errorlevel 1 goto bridgefailed
call npm run build
if errorlevel 1 goto bridgefailed
popd
call flutter pub get
if errorlevel 1 goto failed
call flutter analyze --no-pub
if errorlevel 1 goto failed
call flutter test --no-pub
if errorlevel 1 goto failed
call flutter build web --release --no-pub --no-web-resources-cdn --no-wasm-dry-run
if errorlevel 1 goto failed
cmake -S native\network -B native\network\build-win -A x64 -DMYTIFY_NETWORK_TESTS=ON
if errorlevel 1 goto failed
cmake --build native\network\build-win --config Release
if errorlevel 1 goto failed
ctest --test-dir native\network\build-win -C Release --output-on-failure -R "^airplay_"
if errorlevel 1 goto failed
pushd native\mytify_core
cargo test --locked
if errorlevel 1 goto corefailed
cargo build --locked --release --features desktop,embed-ui
if errorlevel 1 goto corefailed
popd
copy /Y native\network\build-win\Release\mytify_airplay.dll native\mytify_core\target\release\mytify_airplay.dll
if errorlevel 1 goto failed
echo Gotowe: native\mytify_core\target\release\mytify.exe
echo Build MSVC linkuje WebView2 Loader statycznie; potrzebny WebView2 Runtime.
pause
exit /b 0
:tools
echo Potrzebne: Flutter 3.50.1, Rust stable MSVC, CMake 3.31+, Node.js z npm,
echo Visual Studio Build Tools z C++ i Windows SDK.
echo Uruchom ten plik z x64 Native Tools Command Prompt for Visual Studio.
echo Instrukcja: README.md
pause
exit /b 1
:bridgefailed
popd
goto failed
:corefailed
popd
:failed
echo Budowanie nie powiodlo sie. Zachowaj komunikat bledu.
pause
exit /b 1
