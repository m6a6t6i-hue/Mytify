@echo off
setlocal
cd /d "%~dp0"
echo Zamknij poprzednie okna Mytify przed migracja.
echo Uzyj tego samego profilu Edge lub Chrome co w wersji 0.1.
echo W aplikacji wybierz Dodaj muzyke - Przenies biblioteke z wersji 0.1.
echo Po zakonczeniu zamknij to okno i uruchom Mytify.exe.
Mytify.exe --browser
if errorlevel 1 pause
