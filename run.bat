@echo off
REM 삼국 패권 실행 진입점.
REM 번들된 LÖVE2D 11.5(lovec = 콘솔 출력 버전)로 project\src 를 구동한다.
REM lovec.exe 는 print 디버그 출력을 콘솔에 보여준다(일반 love.exe 는 숨김).
"%~dp0love-11.5-win64\lovec.exe" "%~dp0project\src"
