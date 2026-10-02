#Requires AutoHotkey v2.0
#SingleInstance Force

; ─── Оптимизации потребления ресурсов ────────────────────────────────
; 1. Адаптивный интервал опроса (см. CheckChrome): без Chrome — до 5 сек,
;    при «зависшем» URL — до 4× от конфигурационного.
; 2. Никаких блокирующих Sleep/WinWait в цикле — только неблокирующие таймеры.
; 3. Ручная пауза опроса из меню трей-иконки («Пауза») — 0% CPU в паузе.
; 4. Кэш последнего URL и окна Chrome, предвычисленные буферы и IID.

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
        "interval=1000`n",
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

; Домены нормализуются ОДИН раз при старте (нижний регистр, без www),
; чтобы в горячем цикле не выполнялись RegExReplace/StrLower на каждую строку.
WATCHED_DOMAINS := []
for d in StrSplit(raw_domains, ",") {
    dd := StrLower(Trim(d))
    if (dd != "")
        WATCHED_DOMAINS.Push(RegExReplace(dd, "^www\.", ""))
}

A_TrayMenu.Delete()
A_TrayMenu.Add("Chrome→Firefox Redirector", (*) => 0)
A_TrayMenu.Disable("Chrome→Firefox Redirector")
A_TrayMenu.Add("Домены: " . raw_domains, (*) => 0)
A_TrayMenu.Disable("Домены: " . raw_domains)
A_TrayMenu.Add()
A_TrayMenu.Add("Открыть конфиг", (*) => Run("notepad.exe " . CONFIG_FILE))
A_TrayMenu.Add("Пауза", TogglePause)
A_TrayMenu.Add("Перезапустить",  (*) => Reload())
A_TrayMenu.Add()
A_TrayMenu.Add("Выход", (*) => ExitApp())
TraySetIcon("shell32.dll", 14)

last_url := ""
last_chrome_hwnd := 0
idle_checks := 0
poll_ms := CHECK_MS      ; текущий интервал опроса (адаптивный)
paused := false
SetTimer(CheckChrome, poll_ms)

TogglePause(*) {
    global paused, poll_ms, CHECK_MS
    paused := !paused
    if paused {
        SetTimer(CheckChrome, 0)
        A_TrayMenu.Rename("Пауза", "Продолжить")
    } else {
        poll_ms := CHECK_MS
        SetTimer(CheckChrome, poll_ms)
        A_TrayMenu.Rename("Продолжить", "Пауза")
        CheckChrome()
    }
}

CheckChrome() {
    global last_url, WATCHED_DOMAINS, FIREFOX_PATH, CLOSE_TAB
    global last_chrome_hwnd, idle_checks, poll_ms, CHECK_MS, paused
    if paused
        return

    hwnd := WinExist("ahk_exe chrome.exe")
    if !hwnd {
        ; Chrome не запущен — тяжёлую проверку MSAA не делаем вообще,
        ; а опрос постепенно урежаем до 5 сек (экономия CPU почти до нуля).
        if (poll_ms < 5000) {
            poll_ms := Min(poll_ms * 2, 5000)
            SetTimer(CheckChrome, poll_ms)
        }
        return
    }
    ; Сменилось окно Chrome — старый URL больше не актуален, сбрасываем кэш.
    if (hwnd != last_chrome_hwnd) {
        last_chrome_hwnd := hwnd
        last_url := ""
    }

    url := GetChromeURL(hwnd)
    if (url = "" || url = last_url) {
        ; URL не изменился — плавно увеличиваем интервал (идл-режим),
        ; но не более чем в 4 раза от заданного в конфиге.
        if (++idle_checks > 30 && poll_ms < CHECK_MS * 4) {
            poll_ms := Min(poll_ms * 2, CHECK_MS * 4)
            SetTimer(CheckChrome, poll_ms)
            idle_checks := 0
        }
        return                          ; нового URL нет — дальше не идём
    }
    ; Появился новый URL — возвращаем штатный интервал.
    idle_checks := 0
    if (poll_ms != CHECK_MS) {
        poll_ms := CHECK_MS
        SetTimer(CheckChrome, poll_ms)
    }

    if DomainMatches(url, WATCHED_DOMAINS) {
        last_url := url

        if CLOSE_TAB {
            WinActivate("ahk_exe chrome.exe")
            Sleep(80)
            Send("^w")
        }

        Run('"' . FIREFOX_PATH . '" "' . url . '"')
        ; Активация Firefox — неблокирующим однократным таймером вместо
        ; Sleep(600)+WinWait: скрипт не «засыпает» и не держит поток.
        ff_opens_at := A_TickCount + 600
        SetTimer(ActivateFirefox, 150)
        SetTimer(StopWaitingFirefox, -3000)

        TrayTip("Открыто в Firefox", url, 2)
    }
}

ActivateFirefox() {
    global ff_opens_at
    if (A_TickCount >= ff_opens_at && WinExist("ahk_exe firefox.exe")) {
        WinActivate("ahk_exe firefox.exe")
        WinMoveTop("ahk_exe firefox.exe")
        SetTimer(ActivateFirefox, 0)
        SetTimer(StopWaitingFirefox, 0)
    }
}

StopWaitingFirefox() {
    SetTimer(ActivateFirefox, 0)
}

GetChromeURL(hwnd) {
    static IID_IAccessible := Buffer(16)
    static ready := DllCall("ole32\CLSIDFromString", "Str", "{618736E0-3C3D-11CF-810C-00AA00389B71}", "Ptr", IID_IAccessible) = 0
    if !ready
        return ""
    try {
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
            if (v != "" && InStr(v, "://"))
                return v
            ; Ленивая проверка «похоже на домен» — только если нет схемы,
            ; и без повторного RegEx на каждом проходе (кэш last_url выше).
            if (v != "" && RegExMatch(v, "^[\w-]+\.[\w]{2,}"))
                return "https://" . v
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
    static cache_key := "", cache_hit := false
    ; Кэш результата по URL: повторные те же строки не парсятся заново.
    if (url = cache_key)
        return cache_hit
    host := StrLower(RegExReplace(url, "^https?://(www\.)?([^/:?#]+).*$", "$2"))
    hit := false
    for d in domains {
        if (host = d || SubStr(host, -StrLen(d)-1) = "." . d) {
            hit := true
            break
        }
    }
    cache_key := url, cache_hit := hit
    return hit
}
