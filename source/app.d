/**
 * Einfache Win32-GUI-Anwendung in D.
 *
 * - Hauptfenster mit Menü (Datei / Bearbeiten / Hilfe)
 * - Liste aller Dateien und Verzeichnisse im TMP-Verzeichnis, die zuletzt
 *   vor der letzten Mitternacht (lokale Zeit) geändert wurden
 * - Suche nach dem Namen (Filter, Groß-/Kleinschreibung egal)
 * - Alle markieren und markierte Einträge in den Papierkorb verschieben
 */
module app;

version (Windows) {} else static assert(0, "Diese Anwendung läuft nur unter Windows.");

import core.sys.windows.windows;
import core.sys.windows.commctrl;
import core.sys.windows.shellapi;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.format : format;
import std.uni : toLower;
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
// IDs und Konstanten
// ---------------------------------------------------------------------------

enum : UINT
{
    IDM_FILE_FIND     = 1001,
    IDM_FILE_REFRESH  = 1002,
    IDM_FILE_EXIT     = 1003,
    IDM_EDIT_SELALL   = 1004,
    IDM_EDIT_RECYCLE  = 1005,
    IDM_HELP_ABOUT    = 1006,
}

enum : UINT
{
    IDC_SEARCH_LABEL  = 3001,
    IDC_SEARCH_EDIT   = 3002,
    IDC_SELALL_BUTTON = 3003,
    IDC_RECYCLE_BUTTON = 3004,
    IDC_INFO_LABEL    = 3005,
    IDC_FILE_LIST     = 3006,
}

/// Eigene Nachricht: Info-Zeile und Buttons aktualisieren (gebündelt).
enum UINT WM_APP_UPDATE_STATUS = WM_APP + 1;

enum UINT EM_SETCUEBANNER_       = 0x1501;  // ECM_FIRST + 1
enum WORD FOF_WANTNUKEWARNING_   = 0x4000;

// Layout (Pixel)
enum margin       = 8;
enum rowHeight    = 24;
enum buttonWidth  = 130;
enum labelWidth   = 45;
enum listTop      = margin + rowHeight + 6 + 20 + 6;

immutable wstring windowClassName = "Win32DTestMainWindow"w;

// ---------------------------------------------------------------------------
// Globaler Zustand
// ---------------------------------------------------------------------------

/// Ein Eintrag im TMP-Verzeichnis.
struct TmpEntry
{
    wstring name;
    wstring lowerName; // für die Suche
    bool isDirectory;
    FILETIME lastWrite; // UTC
    ulong size;
}

__gshared HINSTANCE g_hInstance;
__gshared HWND g_mainWindow;
__gshared HWND g_searchLabel;
__gshared HWND g_searchEdit;
__gshared HWND g_selAllButton;
__gshared HWND g_recycleButton;
__gshared HWND g_infoLabel;
__gshared HWND g_fileList;

/// Alle gefundenen Einträge (vor Mitternacht geändert).
__gshared TmpEntry[] g_entries;
/// Indizes in g_entries, die aktuell angezeigt werden (Zeile -> Eintrag).
__gshared size_t[] g_view;

__gshared wstring g_tmpDir;
__gshared wstring g_cutoffText;
__gshared bool g_statusUpdatePending;

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
        WS_EX_CONTROLPARENT,
        windowClassName.ptr,
        "Win32 D Testanwendung"w.ptr,
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 820, 520,
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

    // Tastenkürzel: Strg+F (Suche), F5 (Aktualisieren), Strg+A (Alle markieren)
    ACCEL[3] accels = [
        ACCEL(FVIRTKEY | FCONTROL, 'F', cast(WORD) IDM_FILE_FIND),
        ACCEL(FVIRTKEY, VK_F5, cast(WORD) IDM_FILE_REFRESH),
        ACCEL(FVIRTKEY | FCONTROL, 'A', cast(WORD) IDM_EDIT_SELALL),
    ];
    HACCEL hAccel = CreateAcceleratorTableW(accels.ptr, cast(int) accels.length);
    scope (exit) DestroyAcceleratorTable(hAccel);

    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
        if (TranslateAcceleratorW(hwnd, hAccel, &msg))
            continue;
        if (IsDialogMessageW(hwnd, &msg)) // Tab-Navigation zwischen den Steuerelementen
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
    AppendMenuW(fileMenu, MF_STRING, IDM_FILE_FIND, "&Suchen\tStrg+F"w.ptr);
    AppendMenuW(fileMenu, MF_STRING, IDM_FILE_REFRESH, "&Aktualisieren\tF5"w.ptr);
    AppendMenuW(fileMenu, MF_SEPARATOR, 0, null);
    AppendMenuW(fileMenu, MF_STRING, IDM_FILE_EXIT, "&Beenden"w.ptr);

    HMENU editMenu = CreatePopupMenu();
    AppendMenuW(editMenu, MF_STRING, IDM_EDIT_SELALL, "&Alle markieren\tStrg+A"w.ptr);
    AppendMenuW(editMenu, MF_STRING, IDM_EDIT_RECYCLE, "In den &Papierkorb\tEntf"w.ptr);

    HMENU helpMenu = CreatePopupMenu();
    AppendMenuW(helpMenu, MF_STRING, IDM_HELP_ABOUT, "Ü&ber..."w.ptr);

    HMENU menuBar = CreateMenu();
    AppendMenuW(menuBar, MF_POPUP, cast(UINT_PTR) fileMenu, "&Datei"w.ptr);
    AppendMenuW(menuBar, MF_POPUP, cast(UINT_PTR) editMenu, "&Bearbeiten"w.ptr);
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
        case WM_CREATE:
            g_mainWindow = hwnd;
            createChildControls(hwnd);
            refreshFileList();
            return 0;

        case WM_COMMAND:
        {
            UINT id   = LOWORD(cast(DWORD) wParam);
            UINT code = HIWORD(cast(DWORD) wParam);
            switch (id)
            {
                case IDM_FILE_FIND:
                    SetFocus(g_searchEdit);
                    SendMessageW(g_searchEdit, EM_SETSEL, 0, -1);
                    return 0;

                case IDM_FILE_REFRESH:
                    refreshFileList();
                    return 0;

                case IDM_FILE_EXIT:
                    DestroyWindow(hwnd);
                    return 0;

                case IDM_EDIT_SELALL:
                    // Strg+A im Suchfeld markiert den Suchtext, sonst alle Listeneinträge
                    if (GetFocus() == g_searchEdit)
                        SendMessageW(g_searchEdit, EM_SETSEL, 0, -1);
                    else
                        selectAll();
                    return 0;

                case IDC_SELALL_BUTTON:
                    selectAll();
                    SetFocus(g_fileList);
                    return 0;

                case IDM_EDIT_RECYCLE:
                case IDC_RECYCLE_BUTTON:
                    moveSelectedToRecycleBin(hwnd);
                    return 0;

                case IDC_SEARCH_EDIT:
                    if (code == EN_CHANGE)
                        applyFilter();
                    return 0;

                case IDM_HELP_ABOUT:
                    MessageBoxW(hwnd,
                        ("Win32 D Testanwendung\n\n"w ~
                         "Listet Einträge im TMP-Verzeichnis, die vor Mitternacht geändert wurden.\n"w ~
                         "Suche nach Namen, Alle markieren, In den Papierkorb verschieben.\0"w).ptr,
                        "Über"w.ptr, MB_OK | MB_ICONINFORMATION);
                    return 0;

                default:
                    break;
            }
            break;
        }

        case WM_NOTIFY:
        {
            auto hdr = cast(NMHDR*) lParam;
            if (hdr.hwndFrom == g_fileList)
            {
                if (hdr.code == LVN_ITEMCHANGED)
                {
                    scheduleStatusUpdate();
                }
                else if (hdr.code == LVN_KEYDOWN)
                {
                    auto kd = cast(NMLVKEYDOWN*) lParam;
                    if (kd.wVKey == VK_DELETE)
                        moveSelectedToRecycleBin(hwnd);
                }
            }
            break;
        }

        case WM_APP_UPDATE_STATUS:
            g_statusUpdatePending = false;
            updateStatus();
            return 0;

        case WM_SIZE:
            layoutControls(LOWORD(cast(DWORD) lParam), HIWORD(cast(DWORD) lParam));
            return 0;

        case WM_SETFOCUS:
            SetFocus(g_fileList);
            return 0;

        case WM_CTLCOLORSTATIC:
            // Beschriftungen mit dem gleichen Hintergrund wie das Fenster zeichnen
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
// Steuerelemente
// ---------------------------------------------------------------------------

HWND createControl(HWND parent, DWORD exStyle, wstring className, wstring text,
                   DWORD style, UINT id) nothrow
{
    wstring cls = className ~ "\0"w;
    wstring txt = text ~ "\0"w;
    HWND h = CreateWindowExW(exStyle, cls.ptr, txt.ptr, WS_CHILD | WS_VISIBLE | style,
        0, 0, 0, 0, parent, cast(HMENU) cast(size_t) id, g_hInstance, null);
    SendMessageW(h, WM_SETFONT, cast(WPARAM) GetStockObject(DEFAULT_GUI_FONT), TRUE);
    return h;
}

void createChildControls(HWND parent) nothrow
{
    g_searchLabel = createControl(parent, 0, "STATIC"w, "Suche:"w,
        SS_LEFT | SS_CENTERIMAGE, IDC_SEARCH_LABEL);

    g_searchEdit = createControl(parent, WS_EX_CLIENTEDGE, "EDIT"w, ""w,
        WS_TABSTOP | ES_AUTOHSCROLL, IDC_SEARCH_EDIT);
    SendMessageW(g_searchEdit, EM_SETCUEBANNER_, TRUE,
                 cast(LPARAM) "Name enthält ..."w.ptr);

    g_selAllButton = createControl(parent, 0, "BUTTON"w, "Alle &markieren"w,
        WS_TABSTOP | BS_PUSHBUTTON, IDC_SELALL_BUTTON);

    g_recycleButton = createControl(parent, 0, "BUTTON"w, "In den &Papierkorb"w,
        WS_TABSTOP | BS_PUSHBUTTON, IDC_RECYCLE_BUTTON);

    g_infoLabel = createControl(parent, 0, "STATIC"w, ""w,
        SS_LEFT | SS_CENTERIMAGE, IDC_INFO_LABEL);

    g_fileList = createControl(parent, WS_EX_CLIENTEDGE, "SysListView32"w, ""w,
        WS_TABSTOP | LVS_REPORT | LVS_SHOWSELALWAYS, IDC_FILE_LIST);
    SendMessageW(g_fileList, LVM_SETEXTENDEDLISTVIEWSTYLE, 0,
                 LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES);

    addColumn(0, "Name"w,                360, LVCFMT_LEFT);
    addColumn(1, "Typ"w,                 90,  LVCFMT_LEFT);
    addColumn(2, "Zuletzt geändert"w,    140, LVCFMT_LEFT);
    addColumn(3, "Größe (Bytes)"w,       110, LVCFMT_RIGHT); // rechtsbündig
}

void layoutControls(int w, int h) nothrow
{
    int y = margin;
    int x = margin;
    MoveWindow(g_searchLabel, x, y, labelWidth, rowHeight, TRUE);
    x += labelWidth;

    int buttonsWidth = 2 * buttonWidth + 2 * 6;
    int editWidth = w - x - margin - buttonsWidth - 6;
    if (editWidth < 80)
        editWidth = 80;
    MoveWindow(g_searchEdit, x, y, editWidth, rowHeight, TRUE);
    x += editWidth + 6;

    MoveWindow(g_selAllButton, x, y, buttonWidth, rowHeight, TRUE);
    x += buttonWidth + 6;
    MoveWindow(g_recycleButton, x, y, buttonWidth, rowHeight, TRUE);

    y += rowHeight + 6;
    MoveWindow(g_infoLabel, margin, y, w - 2 * margin, 20, TRUE);

    MoveWindow(g_fileList, 0, listTop, w, h - listTop, TRUE);
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

// ---------------------------------------------------------------------------
// TMP-Verzeichnis einlesen
// ---------------------------------------------------------------------------

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
TmpEntry[] findEntriesBefore(wstring dir, FILETIME cutoff)
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
            e.lowerName   = toLower(name);
            e.isDirectory = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            e.lastWrite   = fd.ftLastWriteTime;
            e.size        = (cast(ulong) fd.nFileSizeHigh << 32) | fd.nFileSizeLow;
            result ~= e;
        }
    }
    while (FindNextFileW(h, &fd));

    return result;
}

/// Liest das TMP-Verzeichnis neu ein und zeigt die Einträge (gefiltert) an.
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
        g_entries = entries;
    }
    catch (Exception e)
    {
        g_entries = null;
        MessageBoxW(g_mainWindow,
                    ("Fehler beim Lesen des TMP-Verzeichnisses:\n"w ~ e.msg.toUTF16 ~ "\0"w).ptr,
                    "Fehler"w.ptr, MB_OK | MB_ICONERROR);
    }
    applyFilter();
}

// ---------------------------------------------------------------------------
// Suche
// ---------------------------------------------------------------------------

/// Liefert den aktuellen Suchtext in Kleinbuchstaben.
wstring currentSearchText() nothrow
{
    int len = GetWindowTextLengthW(g_searchEdit);
    if (len <= 0)
        return null;
    auto buf = new wchar[len + 1];
    len = GetWindowTextW(g_searchEdit, buf.ptr, len + 1);
    try
        return toLower(buf[0 .. len].idup);
    catch (Exception)
        return buf[0 .. len].idup;
}

/// Füllt die Liste mit allen Einträgen, deren Name den Suchtext enthält.
void applyFilter() nothrow
{
    wstring needle = currentSearchText();

    g_view = null;
    foreach (i, ref e; g_entries)
    {
        bool match = true;
        if (needle.length)
        {
            try
                match = e.lowerName.canFind(needle);
            catch (Exception)
                match = false;
        }
        if (match)
            g_view ~= i;
    }

    SendMessageW(g_fileList, WM_SETREDRAW, FALSE, 0);
    SendMessageW(g_fileList, LVM_DELETEALLITEMS, 0, 0);
    foreach (row, idx; g_view)
    {
        auto e = &g_entries[idx];
        int r = cast(int) row;
        setCell(r, 0, e.name);
        setCell(r, 1, e.isDirectory ? "Verzeichnis"w : "Datei"w);
        try
        {
            setCell(r, 2, formatFileTime(e.lastWrite));
            setCell(r, 3, e.isDirectory ? ""w : format("%d"w, e.size));
        }
        catch (Exception) {}
    }
    SendMessageW(g_fileList, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(g_fileList, null, TRUE);

    updateStatus();
}

// ---------------------------------------------------------------------------
// Markieren und Papierkorb
// ---------------------------------------------------------------------------

/// Markiert (selektiert) alle angezeigten Einträge.
void selectAll() nothrow
{
    LVITEMW item;
    item.stateMask = LVIS_SELECTED;
    item.state     = LVIS_SELECTED;
    // Index -1: gilt für alle Einträge
    SendMessageW(g_fileList, LVM_SETITEMSTATE, cast(WPARAM) -1, cast(LPARAM) &item);
}

/// Liefert die Indizes (in g_entries) aller markierten Zeilen.
size_t[] selectedEntries() nothrow
{
    size_t[] result;
    int row = -1;
    for (;;)
    {
        row = cast(int) SendMessageW(g_fileList, LVM_GETNEXTITEM,
                                     cast(WPARAM) row, LVNI_SELECTED);
        if (row < 0)
            break;
        if (row < g_view.length)
            result ~= g_view[row];
    }
    return result;
}

/// Verschiebt alle markierten Einträge in den Papierkorb.
void moveSelectedToRecycleBin(HWND owner) nothrow
{
    auto selected = selectedEntries();
    if (selected.length == 0)
    {
        MessageBoxW(owner, "Es sind keine Einträge markiert."w.ptr,
                    "Papierkorb"w.ptr, MB_OK | MB_ICONINFORMATION);
        return;
    }

    // pFrom: vollständige Pfade, jeweils mit \0 getrennt, am Ende doppelt \0
    wstring from;
    foreach (idx; selected)
        from ~= g_tmpDir ~ g_entries[idx].name ~ "\0"w;
    from ~= "\0"w;

    SHFILEOPSTRUCTW op;
    op.hwnd   = owner;
    op.wFunc  = FO_DELETE;
    op.pFrom  = from.ptr;
    // FOF_ALLOWUNDO = Papierkorb statt endgültigem Löschen.
    // Windows fragt selbst nach einer Bestätigung und warnt, falls ein
    // Eintrag nicht in den Papierkorb verschoben werden kann.
    op.fFlags = cast(WORD)(FOF_ALLOWUNDO | FOF_WANTNUKEWARNING_);

    int rc = SHFileOperationW(&op);
    if (rc != 0 && !op.fAnyOperationsAborted)
    {
        try
        {
            wstring text = format("Die Einträge konnten nicht in den Papierkorb verschoben werden (Fehler 0x%X).\0"w, rc);
            MessageBoxW(owner, text.ptr, "Papierkorb"w.ptr, MB_OK | MB_ICONERROR);
        }
        catch (Exception) {}
    }

    refreshFileList();
}

// ---------------------------------------------------------------------------
// Info-Zeile
// ---------------------------------------------------------------------------

/// Bündelt viele LVN_ITEMCHANGED-Nachrichten (z. B. bei "Alle markieren") zu einem Update.
void scheduleStatusUpdate() nothrow
{
    if (!g_statusUpdatePending)
    {
        g_statusUpdatePending = true;
        PostMessageW(g_mainWindow, WM_APP_UPDATE_STATUS, 0, 0);
    }
}

void updateStatus() nothrow
{
    auto selCount = cast(size_t) SendMessageW(g_fileList, LVM_GETSELECTEDCOUNT, 0, 0);
    EnableWindow(g_recycleButton, selCount > 0);

    try
    {
        wstring text = format("%d von %d Einträgen angezeigt, %d markiert  –  %s, zuletzt geändert vor %s\0"w,
                              g_view.length, g_entries.length, selCount, g_tmpDir, g_cutoffText);
        SetWindowTextW(g_infoLabel, text.ptr);
    }
    catch (Exception)
    {
        SetWindowTextW(g_infoLabel, ""w.ptr);
    }
}
