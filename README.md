<p align="center"><img src="Design/paperboy-icon.png" width="140" alt="Paperboy"></p>

<h1 align="center">Paperboy</h1>

<p align="center"><b>Reggeli újság a reMarkable tabletre.</b><br>
Kedvenc hírforrásaidból minden nap egy olvasható, jegyzetelhető PDF-kiadás – magától kerül fel a tabletre, amikor bedugod.</p>

<p align="center"><img src="Design/screenshot-app.png" width="820" alt="A Paperboy főablaka"></p>

## Mit tud?

**Hírforrások címkékkel**
- RSS- és Atom-hírcsatornák kezelése egy listában, tetszőleges címkékkel (pl. *Napi*, *Tech*). Egy forrás több címkéhez is tartozhat.
- Új forrásnál az „Ellenőrzés” lekéri a csatornát, kitölti a nevét, és megmondja, hány cikket talált.
- Forrásonként ki-be kapcsolható; az oldalsávban címke szerint szűrhető.

**Napi kiadás címkénként**
- Minden címkéből egy PDF készül `Napi – 2026-10-05` néven, a reMarkable képernyőjére méretezve.
- A címoldalon kattintható tartalomjegyzék, minden cikk új oldalon kezdődik, és mindegyikről vissza lehet ugrani a tartalomhoz.
- Csak a még fel nem töltött cikkek kerülnek bele, így nincs ismétlődés. Beállítható, hány cikk és milyen régi hírek kerüljenek be.

<p align="center"><img src="Design/screenshot-edition.png" width="720" alt="Egy napi kiadás címoldala és egy cikk oldala"></p>

**Teljes cikkek, képekkel**
- Sok hírcsatorna csak egy-két mondatos kivonatot ad. Forrásonként bekapcsolható, hogy a Paperboy a cikk weboldaláról töltse le a teljes szöveget – a Firefox olvasó nézetéből ismert [Mozilla Readability](https://github.com/mozilla/readability) segítségével, a menük, ajánlók és megosztógombok nélkül.
- A képek e-ink-barát módon kerülnek be: szürkeárnyalatosan, a tablet felbontására kicsinyítve, képaláírásokkal. A követőpixeleket, ikonokat és szerzői fotókat kiszűri.

**Automatikus szinkronizálás**
- A tablet csatlakoztatását magától észleli, és feltölti az aznapi kiadásokat a tablet megadott mappájába – USB web interface-en (ajánlott) vagy SSH-n (lásd [Feltöltési módok](#feltöltési-módok)).
- Alapból naponta egyszer, reggel 6-tól; beállítható minden csatlakozásra is.
- A háttérben, a menüsorban fut; indulhat bejelentkezéskor, és értesítést küld, amikor friss hírek kerültek fel.
- Előnézet: a kiadások tablet nélkül, helyben is elkészíthetők és megnézhetők.

## Követelmények

- macOS 14 (Sonoma) vagy újabb, Swift 5.10+ (Xcode vagy Command Line Tools)
- reMarkable 2 vagy Paper Pro, USB-kábel

## Telepítés

**Kész alkalmazás:** a [Releases](https://github.com/plyk/paperboy/releases) oldalról töltsd le a legújabb `Paperboy-X.Y.Z.zip`-et, csomagold ki, és húzd a `Paperboy.app`-ot az Alkalmazások mappába. Az alkalmazás nincs Apple-fejlesztői tanúsítvánnyal aláírva, ezért első indításkor a macOS letiltja: ilyenkor a Rendszerbeállítások → Adatvédelem és biztonság alján válaszd a „Megnyitás mindenképp” lehetőséget.

**Forrásból:**

```sh
git clone git@github.com:plyk/paperboy.git
cd paperboy
./scripts/build-app.sh            # → build/Paperboy.app
cp -R build/Paperboy.app /Applications/
```

Fejlesztéshez `swift run` is elég.

## Első lépések

1. **A tableten:** Beállítások → Tárhely → kapcsold be az **USB web interface**-t, és hozd létre a célmappát (alapból `Hírek`).
2. **A Paperboyban:** add hozzá a hírforrásokat a **+** gombbal, és címkézd fel őket. Címke nélküli forrás az „Egyéb” kiadásba kerül.
3. **Próbáld ki** az **Előnézet** gombbal, majd dugd be és oldd fel a tabletet – a szinkronizálás magától elindul.
4. A **Beállításokban** (⌘,) állítható a célmappa, a cikkek száma, a képek, a teljes szöveg és az automatikus frissítés, valamint az indítás bejelentkezéskor.

## Feltöltési módok

> [!IMPORTANT]
> **Az ajánlott mód az USB web interface.** Ilyenkor a PDF-et maga a tablet felülete veszi át – ugyanúgy, mint a hivatalos alkalmazásnál vagy a felhős szinkronnál –, ezért a kiadás azonnal megjelenik, és a tablet felülete soha nem indul újra. Az SSH-s mód csak akkor érdemes, ha kifejezetten kell valamelyik előnye (lásd lent), és elfogadható, hogy minden feltöltés után pár másodpercre újraindul a tablet felülete.

### USB web interface (ajánlott)

- Kábelen működik, jelszó nélkül; a tableten be kell kapcsolni: Beállítások → Tárhely → USB web interface.
- Az új kiadások újraindítás nélkül, azonnal megjelennek.
- A célmappát egyszer kézzel kell létrehozni a tableten, mert ez a felület mappát nem tud létrehozni.

### SSH

A Paperboy SSH-n is tud feltölteni (Beállítások → reMarkable → Feltöltés módja). Előnyei:

- a célmappát maga hozza létre, a dokumentumnevek `.pdf` nélkül jelennek meg, és nem kell bekapcsolni a web interface-t;
- Wi-Fi-n is működhet, ha a tableten engedélyezve van az SSH Wi-Fi-n, és a tablet címét megadod;
- bekapcsolható, hogy a régi kiadások egy idő után a Kukába kerüljenek – csak a Paperboy által létrehozott, **jegyzet nélküli** kiadások, és a Kukából visszaállíthatók.

**Miért indul újra a tablet felülete?** SSH-n a Paperboy közvetlenül a tablet dokumentumtárába írja a fájlokat. A tablet felülete (`xochitl`) ezt a tárat csak induláskor olvassa be, a változásait nem figyeli – így az új dokumentumok csak a felület újraindítása (kb. 7–10 másodperc) után látszanak. Ez nem a PDF-feltöltés sajátja, hanem a közvetlen fájlírásé: minden SSH-s, fájlmásolással dolgozó eszköz ugyanígy működik. A tablet maga nem indul újra, csak a felülete.

Ezért SSH-n:

- **kézi szinkronizálásnál** a felület azonnal újraindul;
- **automatikus szinkronizálásnál** a kiadások felkerülnek, de a felület csak jóváhagyásra indul újra: értesítés érkezik „Újraindítás most” gombbal, és a menüsorból is elindítható. A régi kiadások Kukába helyezése is csak ilyenkor történik.

Beállítás: a root jelszót a tableten a Beállítások → Általános → Súgó → Névjegy → Szerzői jogok és licencek oldalon, a *GPLv3 Compliance* résznél találod. A Beállításokban egyszer megadva a Paperboy feltelepíti vele a saját SSH-kulcsát (`~/Library/Application Support/Paperboy/ssh`), a jelszót nem tárolja. reMarkable Paper Pro-n az SSH-hoz [fejlesztői mód](https://support.remarkable.com/s/article/Developer-mode) kell, ami gyári visszaállítással jár.

Az SSH-s feltöltés nem hivatalos felületen át, közvetlenül a tablet dokumentumtárába ír, ezért egy jövőbeli firmware-frissítés után érdemes ellenőrizni.

## Verziók és kiadások

A verziók [szemantikus verziózást](https://semver.org/lang/hu/) követnek, és `vX.Y.Z` git-címkék jelölik őket. A build script a legutóbbi címkéből írja be a verziót az alkalmazásba, a build-szám pedig a commitok száma; mindkettő látszik a Beállítások alján és a Névjegy ablakban.

Új kiadás a `main` ágról, minden változás commitolása és pusholása után:

```sh
./scripts/release.sh 0.2.0
```

A script létrehozza a `v0.2.0` címkét, elkészíti az alkalmazást, és GitHub Release-t ad ki a letölthető zippel. A kiadási jegyzetet az előző címke óta készült commitokból állítja össze (új funkciók, javítások, egyéb).

## Tudnivalók

- Alapból a tablet **USB web interface**-én keresztül tölt fel (`10.11.99.1`, a Beállításokban átírható), felhő és fiók nélkül. Ez a felület nem tud mappát létrehozni, ezért ott a célmappát előre létre kell hozni.
- A már feltöltött kiadásokat a Paperboy sosem írja felül, hogy a kézzel írt jegyzetek ne vesszenek el; egy nap második kiadása ezért `(2)` jelölést kap.
- Fizetős vagy bejelentkezéshez kötött cikkeknél a hírcsatorna kivonata marad.
- Az adatok helye: `~/Library/Application Support/Paperboy/library.json`.

## Felhasznált összetevők

- [Mozilla Readability](https://github.com/mozilla/readability) 0.6.0 – Apache License 2.0 (`Support/Readability.js`, `Support/Readability-LICENSE.md`)
