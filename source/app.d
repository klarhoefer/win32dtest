/**
 * Einfache Win32-GUI-Anwendung in D.
 *
 * - Hauptfenster mit Menü (Datei / Hilfe)
 * - Liste aller Dateien und Verzeichnisse im TMP-Verzeichnis, die zuletzt
 *   vor der letzten Mitternacht (lokale Zeit) geändert wurden
 * - Modaler Dialog zur Eingabe eines Namens
 *
 * Der Dialog wird zur Laufzeit als DLGTEMPLATE im Speicher aufgebaut,
 * daher ist kein Ressourcen-Compiler (rc.exe) notwendig.
 */
module app;

version (Windows) {} else static assert(0, "Diese Anwendung läuft nur unter Windows.");

import core.sys.windows.windows;
import core.sys.windows.commctrl;
import std.algorithm.sorting : sort;
import std.format : format;
import std.utf : toUTF16, toUTF16z;

/*
 * Manifest-Abhängigkeit auf Common Controls 6.0 für das moderne Aussehen
 * (visuelle Stile). Die Direktive landet in der Objektdatei; der Linker
 * bettet das erzeugte Manifest dank /MANIFEST:EMBED (siehe dub.json) in die
 * EXE ein. Entspricht `#pragma comment(linker, ...)` in C/C++.
 */
pragma(linkerDirective,
    "/manifestdependency:\"type='win32' name='Microsoft.Windows.Common-Controls' " ~
    "version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"");

// ---------------------------------------------------------------------------
// IDs
// ---------------------------------------------------------------------------

enum : UINT
{
    IDM_FILE_NAME  = 1001,
    IDM_FILE_EXIT  = 1002,
    IDM_HELP_ABOUT = 1003,
    IDM_FILE_REFRESH = 1004,
}

enum : UINT
{
    IDC_INFO_LABEL = 3001,
    IDC_FILE_LIST  = 3002,
}

enum infoHeight = 28; // Höhe der Info-Zeile über der Liste in Pixeln

enum : WORD
{
    IDC_NAME_EDIT  = 2001,
    IDC_NAME_LABEL = 2002,
}

immutable wstring windowClassName = "Win32DTestMainWindow"w;

/// Aktueller Name, der im Hauptfenster angezeigt wird.
__gshared wstring g_name = "Welt"w;

/// Instanz-Handle der Anwendung.
__gshared HINSTANCE g_hInstance;

/// Steuerelemente im Hauptfenster.
__gshared HWND g_infoLabel;
__gshared HWND g_fileList;

/// Anzahl und Verzeichnis der zuletzt gelisteten Einträge (für die Info-Zeile).
__gshared size_t g_entryCount;
__gshared wstring g_tmpDir;
__gshared wstring g_cutoffText;

// ---------------------------------------------------------------------------
// Einstiegspunkt
// ---------------------------------------------------------------------------

/*
 * Es wird das normale D-`main` verwendet (Runtime wird automatisch initialisiert).
 * Über die Linker-Flags in dub.json (/SUBSYSTEM:WINDOWS, /ENTRY:mainCRTStartup)
 * wird kein Konsolenfenster geöffnet.
 */
int main()
{
    try
    {
        g_hInstance = GetModuleHandleW(null);
        return runApp(g_hInstance, SW_SHOWDEFAULT);
    }
    catch (Throwable e)
    {
        MessageBoxW(null, e.toString().toUTF16z, "Fehler"w.ptr, MB_OK | MB_ICONERROR);
        return 1;
    }
}

int runApp(HINSTANCE hInstance, int nCmdShow)
{
    INITCOMMONCONTROLSEX icc;
    icc.dwSize = INITCOMMONCONTROLSEX.sizeof;
    icc.dwICC  = ICC_LISTVIEW_CLASSES;
    InitCommonControlsEx(&icc);

    WNDCLASSEXW wc;
    wc.cbSize        = WNDCLASSEXW.sizeof;
    wc.style         = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc   = &mainWndProc;
    wc.hInstance     = hInstance;
    wc.hIcon         = LoadIconW(null, IDI_APPLICATION);
    wc.hIconSm       = LoadIconW(null, IDI_APPLICATION);
    wc.hCursor       = LoadCursorW(null, IDC_ARROW);
    wc.hbrBackground = cast(HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = windowClassName.ptr;

    if (!RegisterClassExW(&wc))
    {
        MessageBoxW(null, "Fensterklasse konnte nicht registriert werden."w.ptr,
                    "Fehler"w.ptr, MB_OK | MB_ICONERROR);
        return 1;
    }

    HWND hwnd = CreateWindowExW(
        0,
        windowClassName.ptr,
        "Win32 D Testanwendung"w.ptr,
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 800, 500,
        null,
        createMainMenu(),
        hInstance,
        null);

    if (hwnd is null)
    {
        MessageBoxW(null, "Fenster konnte nicht erstellt werden."w.ptr,
                    "Fehler"w.ptr, MB_OK | MB_ICONERROR);
        return 1;
    }

    ShowWindow(hwnd, nCmdShow);
    UpdateWindow(hwnd);

    // Tastenkürzel: Strg+N (Name), F5 (Aktualisieren)
    ACCEL[2] accels = [
        ACCEL(FVIRTKEY | FCONTROL, 'N', cast(WORD) IDM_FILE_NAME),
        ACCEL(FVIRTKEY, VK_F5, cast(WORD) IDM_FILE_REFRESH),
    ];
    HACCEL hAccel = CreateAcceleratorTableW(accels.ptr, cast(int) accels.length);
    scope (exit) DestroyAcceleratorTable(hAccel);

    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
        if (TranslateAcceleratorW(hwnd, hAccel, &msg))
            continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return cast(int) msg.wParam;
}

// ---------------------------------------------------------------------------
// Menü
// ---------------------------------------------------------------------------

HMENU createMainMenu()
{
    HMENU fileMenu = CreatePopupMenu();
    AppendMenuW(fileMenu, MF_STRING, IDM_FILE_NAME, "&Name eingeben...\tStrg+N"w.ptr);
    AppendMenuW(fileMenu, MF_STRING, IDM_FILE_REFRESH, "&Aktualisieren\tF5"w.ptr);
    AppendMenuW(fileMenu, MF_SEPARATOR, 0, null);
    AppendMenuW(fileMenu, MF_STRING, IDM_FILE_EXIT, "&Beenden"w.ptr);

    HMENU helpMenu = CreatePopupMenu();
    AppendMenuW(helpMenu, MF_STRING, IDM_HELP_ABOUT, "Ü&ber..."w.ptr);

    HMENU menuBar = CreateMenu();
    AppendMenuW(menuBar, MF_POPUP, cast(UINT_PTR) fileMenu, "&Datei"w.ptr);
    AppendMenuW(menuBar, MF_POPUP, cast(UINT_PTR) helpMenu, "&Hilfe"w.ptr);
    return menuBar;
}

// ---------------------------------------------------------------------------
// Fensterprozedur des Hauptfensters
// ---------------------------------------------------------------------------

extern (Windows)
LRESULT mainWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
        case WM_COMMAND:
            switch (cast(UINT) LOWORD(cast(DWORD) wParam))
            {
                case IDM_FILE_NAME:
                    showNameDialog(hwnd);
                    return 0;

                case IDM_FILE_REFRESH:
                    refreshFileList();
                    return 0;

                case IDM_FILE_EXIT:
                    DestroyWindow(hwnd);
                    return 0;

                case IDM_HELP_ABOUT:
                    MessageBoxW(hwnd,
                        ("Win32 D Testanwendung\n\nEin einfaches Beispiel für Fenster, Menü und Dialog in D.\n"w ~
                         "Listet Einträge im TMP-Verzeichnis, die vor Mitternacht geändert wurden.\0"w).ptr,
                        "Über"w.ptr, MB_OK | MB_ICONINFORMATION);
                    return 0;

                default:
                    break;
            }
            break;

        case WM_CREATE:
            createChildControls(hwnd);
            refreshFileList();
            return 0;

        case WM_SIZE:
        {
            int w = LOWORD(cast(DWORD) lParam);
            int h = HIWORD(cast(DWORD) lParam);
            MoveWindow(g_infoLabel, 8, 6, w - 16, infoHeight - 8, TRUE);
            MoveWindow(g_fileList, 0, infoHeight, w, h - infoHeight, TRUE);
            return 0;
        }

        case WM_SETFOCUS:
            SetFocus(g_fileList);
            return 0;

        case WM_CTLCOLORSTATIC:
            // Info-Zeile mit dem gleichen Hintergrund wie das Fenster zeichnen
            SetBkColor(cast(HDC) wParam, GetSysColor(COLOR_WINDOW));
            return cast(LRESULT) GetSysColorBrush(COLOR_WINDOW);

        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;

        default:
            break;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// ---------------------------------------------------------------------------
// Dateiliste (TMP-Verzeichnis)
// ---------------------------------------------------------------------------

/// Ein Eintrag im TMP-Verzeichnis.
struct TmpEntry
{
    wstring name;
    bool isDirectory;
    FILETIME lastWrite; // UTC
    ulong size;
}

void createChildControls(HWND parent) nothrow
{
    HFONT font = cast(HFONT) GetStockObject(DEFAULT_GUI_FONT);

    g_infoLabel = CreateWindowExW(0, "STATIC"w.ptr, ""w.ptr,
        WS_CHILD | WS_VISIBLE | SS_LEFT | SS_CENTERIMAGE,
        0, 0, 0, 0, parent, cast(HMENU) cast(size_t) IDC_INFO_LABEL, g_hInstance, null);
    SendMessageW(g_infoLabel, WM_SETFONT, cast(WPARAM) font, TRUE);

    g_fileList = CreateWindowExW(WS_EX_CLIENTEDGE, "SysListView32"w.ptr, ""w.ptr,
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | LVS_REPORT | LVS_SHOWSELALWAYS,
        0, 0, 0, 0, parent, cast(HMENU) cast(size_t) IDC_FILE_LIST, g_hInstance, null);
    SendMessageW(g_fileList, WM_SETFONT, cast(WPARAM) font, TRUE);
    SendMessageW(g_fileList, LVM_SETEXTENDEDLISTVIEWSTYLE, 0,
                 LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES);

    addColumn(0, "Name"w,                360, LVCFMT_LEFT);
    addColumn(1, "Typ"w,                 90,  LVCFMT_LEFT);
    addColumn(2, "Zuletzt geändert"w,    140, LVCFMT_LEFT);
    addColumn(3, "Größe (Bytes)"w,       110, LVCFMT_RIGHT); // rechtsbündig
}

void addColumn(int index, wstring title, int width, int align_) nothrow
{
    wstring text = title ~ "\0"w;
    LVCOLUMNW col;
    col.mask     = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM | LVCF_FMT;
    col.fmt      = align_;
    col.cx       = width;
    col.pszText  = cast(LPWSTR) text.ptr;
    col.iSubItem = index;
    SendMessageW(g_fileList, LVM_INSERTCOLUMNW, cast(WPARAM) index, cast(LPARAM) &col);
}

void setCell(int row, int column, wstring value) nothrow
{
    wstring text = value ~ "\0"w;
    LVITEMW item;
    item.mask     = LVIF_TEXT;
    item.iItem    = row;
    item.iSubItem = column;
    item.pszText  = cast(LPWSTR) text.ptr;
    if (column == 0)
        SendMessageW(g_fileList, LVM_INSERTITEMW, 0, cast(LPARAM) &item);
    else
        SendMessageW(g_fileList, LVM_SETITEMTEXTW, cast(WPARAM) row, cast(LPARAM) &item);
}

/// Liefert das TMP-Verzeichnis (GetTempPathW wertet TMP, dann TEMP aus).
wstring tempDirectory() nothrow
{
    wchar[MAX_PATH + 1] buf;
    DWORD len = GetTempPathW(cast(DWORD) buf.length, buf.ptr);
    if (len == 0 || len > buf.length)
        return null;
    return buf[0 .. len].idup;
}

/// Letzte Mitternacht (00:00 Uhr heute, lokale Zeit) als UTC-FILETIME.
FILETIME lastMidnightUtc() nothrow
{
    SYSTEMTIME st;
    GetLocalTime(&st);
    st.wHour = 0;
    st.wMinute = 0;
    st.wSecond = 0;
    st.wMilliseconds = 0;

    FILETIME local, utc;
    SystemTimeToFileTime(&st, &local);
    LocalFileTimeToFileTime(&local, &utc);
    return utc;
}

ulong toUlong(FILETIME ft) nothrow
{
    return (cast(ulong) ft.dwHighDateTime << 32) | ft.dwLowDateTime;
}

/// Formatiert eine UTC-FILETIME als lokale Zeit "TT.MM.JJJJ HH:MM:SS".
wstring formatFileTime(FILETIME utc)
{
    FILETIME local;
    SYSTEMTIME st;
    FileTimeToLocalFileTime(&utc, &local);
    FileTimeToSystemTime(&local, &st);
    return format("%02d.%02d.%04d %02d:%02d:%02d"w,
                  st.wDay, st.wMonth, st.wYear, st.wHour, st.wMinute, st.wSecond);
}

/// Sucht alle Dateien und Verzeichnisse in `dir`, die vor `cutoff` geändert wurden.
TmpEntry[] findEntriesBefore(wstring dir, FILETIME cutoff) nothrow
{
    TmpEntry[] result;
    wstring pattern = dir ~ "*\0"w;

    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pattern.ptr, &fd);
    if (h == INVALID_HANDLE_VALUE)
        return result;
    scope (exit) FindClose(h);

    do
    {
        size_t n = 0;
        while (n < fd.cFileName.length && fd.cFileName[n] != 0)
            ++n;
        wstring name = fd.cFileName[0 .. n].idup;
        if (name == "."w || name == ".."w)
            continue;

        if (CompareFileTime(&fd.ftLastWriteTime, &cutoff) < 0)
        {
            TmpEntry e;
            e.name        = name;
            e.isDirectory = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            e.lastWrite   = fd.ftLastWriteTime;
            e.size        = (cast(ulong) fd.nFileSizeHigh << 32) | fd.nFileSizeLow;
            result ~= e;
        }
    }
    while (FindNextFileW(h, &fd));

    return result;
}

/// Liest das TMP-Verzeichnis neu ein und füllt die Liste.
void refreshFileList() nothrow
{
    try
    {
        g_tmpDir = tempDirectory();
        if (g_tmpDir.length == 0)
            throw new Exception("TMP-Verzeichnis konnte nicht ermittelt werden.");
        FILETIME cutoff = lastMidnightUtc();
        g_cutoffText = formatFileTime(cutoff);

        auto entries = findEntriesBefore(g_tmpDir, cutoff);
        // Verzeichnisse zuerst, dann neueste Änderung zuerst
        entries.sort!((a, b) => a.isDirectory != b.isDirectory
                                ? a.isDirectory
                                : toUlong(a.lastWrite) > toUlong(b.lastWrite));

        SendMessageW(g_fileList, WM_SETREDRAW, FALSE, 0);
        SendMessageW(g_fileList, LVM_DELETEALLITEMS, 0, 0);
        foreach (i, ref e; entries)
        {
            int row = cast(int) i;
            setCell(row, 0, e.name);
            setCell(row, 1, e.isDirectory ? "Verzeichnis"w : "Datei"w);
            setCell(row, 2, formatFileTime(e.lastWrite));
            setCell(row, 3, e.isDirectory ? ""w : format("%d"w, e.size));
        }
        SendMessageW(g_fileList, WM_SETREDRAW, TRUE, 0);
        InvalidateRect(g_fileList, null, TRUE);

        g_entryCount = entries.length;
    }
    catch (Exception e)
    {
        g_entryCount = 0;
        MessageBoxW(null, ("Fehler beim Lesen des TMP-Verzeichnisses:\n"w ~ e.msg.toUTF16 ~ "\0"w).ptr,
                    "Fehler"w.ptr, MB_OK | MB_ICONERROR);
    }
    updateInfoLabel();
}

void updateInfoLabel() nothrow
{
    try
    {
        wstring text = format("Hallo, %s!   %d Einträge in %s, zuletzt geändert vor %s\0"w,
                              g_name, g_entryCount, g_tmpDir, g_cutoffText);
        SetWindowTextW(g_infoLabel, text.ptr);
    }
    catch (Exception)
    {
        SetWindowTextW(g_infoLabel, "Hallo!"w.ptr);
    }
}

// ---------------------------------------------------------------------------
// Dialog
// ---------------------------------------------------------------------------

void showNameDialog(HWND owner) nothrow
{
    auto tmpl = buildNameDialogTemplate();
    INT_PTR res = DialogBoxIndirectParamW(
        g_hInstance,
        cast(const(DLGTEMPLATE)*) tmpl.ptr,
        owner,
        &nameDlgProc,
        0);

    if (res == IDOK)
        updateInfoLabel();
}

extern (Windows)
INT_PTR nameDlgProc(HWND hDlg, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
        case WM_INITDIALOG:
        {
            HWND edit = GetDlgItem(hDlg, IDC_NAME_EDIT);
            wstring current = g_name ~ "\0"w;
            SetWindowTextW(edit, current.ptr);
            SendMessageW(edit, EM_SETSEL, 0, -1);
            SetFocus(edit);
            return FALSE; // Fokus wurde selbst gesetzt
        }

        case WM_COMMAND:
            switch (cast(int) LOWORD(cast(DWORD) wParam))
            {
                case IDOK:
                {
                    wchar[256] buf;
                    int len = GetDlgItemTextW(hDlg, IDC_NAME_EDIT, buf.ptr, cast(int) buf.length);
                    if (len <= 0)
                    {
                        MessageBoxW(hDlg, "Bitte einen Namen eingeben."w.ptr,
                                    "Hinweis"w.ptr, MB_OK | MB_ICONWARNING);
                        SetFocus(GetDlgItem(hDlg, IDC_NAME_EDIT));
                        return TRUE;
                    }
                    g_name = buf[0 .. len].idup;
                    EndDialog(hDlg, IDOK);
                    return TRUE;
                }

                case IDCANCEL:
                    EndDialog(hDlg, IDCANCEL);
                    return TRUE;

                default:
                    break;
            }
            break;

        default:
            break;
    }
    return FALSE;
}

/**
 * Baut ein DLGTEMPLATE für den Namensdialog im Speicher auf.
 *
 * Aufbau (siehe Win32-Doku zu DLGTEMPLATE / DLGITEMTEMPLATE):
 *   DLGTEMPLATE, Menü, Klasse, Titel, [Schriftgröße, Schriftname]
 *   je Steuerelement (DWORD-ausgerichtet):
 *   DLGITEMTEMPLATE, Klasse, Text, Erzeugungsdaten
 */
ushort[] buildNameDialogTemplate() nothrow
{
    DialogTemplateBuilder b;

    b.beginDialog(
        DS_MODALFRAME | DS_CENTER | DS_SETFONT | WS_POPUP | WS_CAPTION | WS_SYSMENU,
        0, 0, 220, 80,
        "Name eingeben"w,
        9, "Segoe UI"w);

    b.addItem(WS_CHILD | WS_VISIBLE | SS_LEFT,
              10, 10, 200, 10, IDC_NAME_LABEL, ATOM_STATIC, "Bitte geben Sie Ihren Namen ein:"w);
    b.addItem(WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL,
              10, 24, 200, 14, IDC_NAME_EDIT, ATOM_EDIT, ""w);
    b.addItem(WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
              104, 56, 50, 14, IDOK, ATOM_BUTTON, "OK"w);
    b.addItem(WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
              160, 56, 50, 14, IDCANCEL, ATOM_BUTTON, "Abbrechen"w);

    return b.finish();
}

enum : ushort
{
    ATOM_BUTTON = 0x0080,
    ATOM_EDIT   = 0x0081,
    ATOM_STATIC = 0x0082,
}

/// Hilfsstruktur zum Aufbau eines DLGTEMPLATE in einem WORD-Puffer.
struct DialogTemplateBuilder
{
    private ushort[] buf;
    private size_t countIndex; // Position des cdit-Feldes

    nothrow:

    private void word(ushort w) { buf ~= w; }
    private void dword(uint d) { buf ~= cast(ushort)(d & 0xFFFF); buf ~= cast(ushort)(d >> 16); }
    private void str(wstring s) { foreach (wchar c; s) buf ~= c; buf ~= 0; }
    private void alignDword() { if (buf.length % 2) buf ~= 0; }

    void beginDialog(uint style, short x, short y, short cx, short cy,
                     wstring title, ushort pointSize, wstring fontName)
    {
        dword(style);
        dword(0);                 // dwExtendedStyle
        countIndex = buf.length;
        word(0);                  // cdit (wird später gesetzt)
        word(cast(ushort) x);
        word(cast(ushort) y);
        word(cast(ushort) cx);
        word(cast(ushort) cy);
        word(0);                  // kein Menü
        word(0);                  // Standard-Dialogklasse
        str(title);
        if (style & DS_SETFONT)
        {
            word(pointSize);
            str(fontName);
        }
    }

    void addItem(uint style, short x, short y, short cx, short cy,
                 ushort id, ushort classAtom, wstring text)
    {
        alignDword();
        dword(style);
        dword(0);                 // dwExtendedStyle
        word(cast(ushort) x);
        word(cast(ushort) y);
        word(cast(ushort) cx);
        word(cast(ushort) cy);
        word(id);
        word(0xFFFF);             // vordefinierte Klasse (Atom)
        word(classAtom);
        str(text);
        word(0);                  // keine Erzeugungsdaten
        buf[countIndex]++;
    }

    ushort[] finish() { return buf; }
}
