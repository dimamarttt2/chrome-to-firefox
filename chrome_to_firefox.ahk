#Requires AutoHotkey v2.0
#SingleInstance Force

CONFIG_FILE := A_ScriptDir . "\config.ini"

if !FileExist(CONFIG_FILE) {
    FileAppend(
        "; Chrome → Firefox Redirector — конфиг`n"
        ";`n"
        "; Домены через запятую (без www, без пробелов):`n"
        "domains=nexusmods.com`n"
        ";`n"
        "; Путь к Firefox:`n"
        "firefox=C:\Program Files\Mozilla Firefox\firefox.exe`n"
        ";`n"
        "; Закрывать вкладку в Chrome после открытия в Firefox? (true/false)`n"
        "close_tab=true`n"
        ";`n"
        "; Интервал проверки в миллисекундах`n"
        "interval=500`n",
        CONFIG_FILE
    )
    MsgBox(
        "Создан файл конфига:`n" . CONFIG_FILE .
        "`n`nОткрою его для редактирования.`nПосле сохранения перезапусти скрипт.",
        "Chrome→Firefox — первый запуск", 64
    )
    Run("notepad.exe " . CONFIG_FILE)
    ExitApp()
}

ReadCfg(key, default) {
    global CONFIG_FILE
    loop read CONFIG_FILE {
        line := Trim(A_LoopReadLine)
        if (SubStr(line, 1, 1) = ";") || (line = "")
            continue
        if RegExMatch(line, "^" . key . "\s*=\s*(.+)$", &m)
            return Trim(m[1])
    }
    return default
}

raw_domains  := ReadCfg("domains",  "nexusmods.com")
FIREFOX_PATH := ReadCfg("firefox",  "C:\Program Files\Mozilla Firefox\firefox.exe")
CLOSE_TAB    := ReadCfg("close_tab","true") = "true"
CHECK_MS     := Integer(ReadCfg("interval", "500"))

WATCHED_DOMAINS := []
for d in StrSplit(raw_domains, ",")
    WATCHED_DOMAINS.Push(Trim(d))

A_TrayMenu.Delete()
A_TrayMenu.Add("Chrome→Firefox Redirector", (*) => 0)
A_TrayMenu.Disable("Chrome→Firefox Redirector")
A_TrayMenu.Add("Домены: " . raw_domains, (*) => 0)
A_TrayMenu.Disable("Домены: " . raw_domains)
A_TrayMenu.Add()
A_TrayMenu.Add("Открыть конфиг", (*) => Run("notepad.exe " . CONFIG_FILE))
A_TrayMenu.Add("Перезапустить",  (*) => Reload())
A_TrayMenu.Add()
A_TrayMenu.Add("Выход", (*) => ExitApp())
TraySetIcon("shell32.dll", 14)

last_url := ""
SetTimer(CheckChrome, CHECK_MS)

CheckChrome() {
    global last_url, WATCHED_DOMAINS, FIREFOX_PATH, CLOSE_TAB

    url := GetChromeURL()
    if (url = "" || url = last_url)
        return

    if DomainMatches(url, WATCHED_DOMAINS) {
        last_url := url

        if CLOSE_TAB {
            hwnd := WinExist("ahk_exe chrome.exe")
            if hwnd {
                WinActivate("ahk_exe chrome.exe")
                Sleep(80)
                Send("^w")
            }
        }

        Run('"' . FIREFOX_PATH . '" "' . url . '"')
        Sleep(600)
        if WinWait("ahk_exe firefox.exe",, 3) {
            WinActivate("ahk_exe firefox.exe")
            WinMoveTop("ahk_exe firefox.exe")
        }

        TrayTip("Открыто в Firefox", url, 2)
    }
}

GetChromeURL() {
    hwnd := WinExist("ahk_exe chrome.exe")
    if !hwnd
        return ""
    try {
        IID_IAccessible := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{618736E0-3C3D-11CF-810C-00AA00389B71}", "Ptr", IID_IAccessible)
        accObj := ComValue(9, 0)
        if DllCall("oleacc\AccessibleObjectFromWindow", "Ptr", hwnd, "UInt", 0xFFFFFFFC, "Ptr", IID_IAccessible, "Ptr*", accObj) != 0
            return ""
        return FindAddressBar(accObj, 0)
    } catch {
        return ""
    }
}

FindAddressBar(acc, depth) {
    if (depth > 10)
        return ""
    try {
        if (acc.accRole(0) = 42) {
            v := Trim(acc.accValue(0))
            if (v != "" && (InStr(v, "://") || RegExMatch(v, "^[\w-]+\.[\w]{2,}"))) {
                if InStr(v, "://")
                    return v
                return "https://" . v
            }
        }
    } catch {
        ; игнорируем
    }
    try {
        cnt := acc.accChildCount
        loop Min(cnt, 30) {
            try {
                child := acc.accChild(A_Index)
                if IsObject(child) {
                    r := FindAddressBar(child, depth + 1)
                    if (r != "")
                        return r
                }
            } catch {
                ; игнорируем
            }
        }
    } catch {
        ; игнорируем
    }
    return ""
}

DomainMatches(url, domains) {
    host := StrLower(RegExReplace(url, "^https?://(www\.)?([^/:?#]+).*$", "$2"))
    for domain in domains {
        d := StrLower(RegExReplace(domain, "^www\.", ""))
        if (host = d || SubStr(host, -StrLen(d)-1) = "." . d)
            return true
    }
    return false
}
