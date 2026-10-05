# Paperboy

Reggeli újság a reMarkable tabletre: macOS-alkalmazás, amely címkézett RSS/Atom hírforrásokból napi PDF-kiadásokat készít, és USB-n keresztül feltölti őket a reMarkable tablet egy megadott mappájába.

## Build

```sh
./scripts/build-app.sh        # → build/RemarkableFeeds.app
swift run                     # fejlesztéshez
```

## Használat

1. A tableten: Beállítások → Tárhely → **USB web interface** bekapcsolása, és a célmappa létrehozása (alapértelmezés: `Hírek`).
2. Az alkalmazásban add hozzá a hírforrásokat és címkézd fel őket. Címke nélküli forrás az „Egyéb” kiadásba kerül.
3. **Előnézet**: a PDF-ek elkészülnek helyben, tablet nélkül.
4. **Szinkronizálás**: minden címkéből `Címke – ÉÉÉÉ-HH-NN` PDF készül, csak a még fel nem töltött cikkekkel.
5. **Automatikus frissítés**: az alkalmazás a menüsorban fut tovább, és alapból naponta egyszer, a tablet csatlakoztatásakor (legkorábban 6:00-tól) magától szinkronizál. A Beállításokban átállítható minden csatlakozásra vagy kikapcsolható; ugyanitt kapcsolható be az indítás bejelentkezéskor.

Az adatok helye: `~/Library/Application Support/RemarkableFeeds/library.json`.

## Korlátok

- Az USB-felület nem tud mappát létrehozni, és nem tud fájlt felülírni vagy törölni.
- A teljes cikk letöltése hírforrásonként kapcsolható be (Mozilla Readability.js, Apache-2.0, `Support/`). Fizetős vagy hibás oldalaknál a hírcsatorna szövege marad.
- A képek szürkeárnyalatosan, legfeljebb 1200 px-re kicsinyítve kerülnek be (cikkenként max. 8); a Beállításokban kikapcsolható.
