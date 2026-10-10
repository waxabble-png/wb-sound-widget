@echo off
REM wb-plugin.cmd - switch wb-sound-widget between "plugin install" and "global hooks install"
REM
REM   wb-plugin.cmd status                show which install method is active
REM   wb-plugin.cmd enable                switch to plugin install (removes global hooks)
REM   wb-plugin.cmd enable --keep-hooks   register the plugin but keep global hooks
REM   wb-plugin.cmd disable               switch back to global hooks install
setlocal
node "%~dp0wb-plugin.mjs" %*
