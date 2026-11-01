/**
 * Einfache Win32-GUI-Anwendung in D.
 *
 * - Hauptfenster mit Menü (Datei / Hilfe)
 * - Modaler Dialog zur Eingabe eines Namens
 *
 * Der Dialog wird zur Laufzeit als DLGTEMPLATE im Speicher aufgebaut,
 * daher ist kein Ressourcen-Compiler (rc.exe) notwendig.
 */
module app;

version (Windows) {} else static assert(0, "Diese Anwendung läuft nur unter Windows.");

import core.sys.windows.windows;
import std.utf : toUTF16z;

// ---------------------------------------------------------------------------
// IDs
// ---------------------------------------------------------------------------

enum : UINT
{
    IDM_FILE_NAME  = 1001,
    IDM_FILE_EXIT  = 1002,
    IDM_HELP_ABOUT = 1003,
}

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
        CW_USEDEFAULT, CW_USEDEFAULT, 640, 400,
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

    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
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

                case IDM_FILE_EXIT:
                    DestroyWindow(hwnd);
                    return 0;

                case IDM_HELP_ABOUT:
                    MessageBoxW(hwnd,
                        "Win32 D Testanwendung\n\nEin einfaches Beispiel für Fenster, Menü und Dialog in D."w.ptr,
                        "Über"w.ptr, MB_OK | MB_ICONINFORMATION);
                    return 0;

                default:
                    break;
            }
            break;

        case WM_KEYDOWN:
            // Einfaches Tastenkürzel Strg+N für den Namensdialog
            if (wParam == 'N' && (GetKeyState(VK_CONTROL) & 0x8000))
            {
                showNameDialog(hwnd);
                return 0;
            }
            break;

        case WM_PAINT:
        {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hwnd, &ps);

            RECT rc;
            GetClientRect(hwnd, &rc);

            HFONT font = cast(HFONT) GetStockObject(DEFAULT_GUI_FONT);
            HGDIOBJ oldFont = SelectObject(hdc, font);
            SetBkMode(hdc, TRANSPARENT);

            wstring text = "Hallo, "w ~ g_name ~ "!"w;
            DrawTextW(hdc, text.ptr, cast(int) text.length, &rc,
                      DT_CENTER | DT_VCENTER | DT_SINGLELINE);

            SelectObject(hdc, oldFont);
            EndPaint(hwnd, &ps);
            return 0;
        }

        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;

        default:
            break;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
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
        InvalidateRect(owner, null, TRUE);
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
