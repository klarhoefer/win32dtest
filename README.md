# win32dtest

Einfache Win32-GUI-Anwendung in D (nur `core.sys.windows`, keine externen Bibliotheken).

- **Fenster** mit zentriertem Begrüßungstext
- **Menü**: *Datei → Name eingeben… / Beenden*, *Hilfe → Über…*
- **Dialog**: modaler Dialog mit Textfeld, OK und Abbrechen. Das Dialog-Template
  wird zur Laufzeit im Speicher erzeugt (`DialogBoxIndirectParamW`), daher wird
  kein Ressourcen-Compiler benötigt.

## Bauen und Starten (Windows)

Voraussetzung: DMD oder LDC sowie dub.

```bash
dub run
```

Mit LDC:

```bash
dub run --compiler=ldc2
```

Die Linker-Flags `/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup` sorgen dafür, dass kein
Konsolenfenster geöffnet wird, obwohl das normale D-`main` verwendet wird.
