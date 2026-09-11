@echo off
REM Сборка Zyng.exe на своём компьютере (нужен Python 3.10+)
echo === Zyng build ===

echo [1/3] Ставлю PyInstaller...
pip install pyinstaller customtkinter pillow

echo [2/3] Скачиваю ядро xray...
powershell -Command "Invoke-WebRequest -Uri 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-windows-64.zip' -OutFile 'xray.zip'; Expand-Archive -Path 'xray.zip' -DestinationPath 'xray_bin' -Force; Copy-Item 'xray_bin\xray.exe' 'xray.exe' -Force"

echo [2.5/3] Скачиваю флаги...
if not exist flags mkdir flags
for %%c in (fr de fi us my nl ru gb pl se tr jp sg ca es it ua lv ee lt ch at hk kr in ae kz ge) do powershell -Command "try{Invoke-WebRequest -Uri 'https://flagcdn.com/w80/%%c.png' -OutFile 'flags/%%c.png'}catch{}"

echo [3/3] Собираю EXE...
pyinstaller --noconfirm --onefile --windowed --name "Zyng" --icon "icon.ico" --collect-all customtkinter --add-binary "xray.exe;." --add-data "logo_white.png;." --add-data "icon.ico;." --add-data "flags;flags" qipcall.py

echo.
echo Готово! Файл: dist\Zyng.exe
pause
