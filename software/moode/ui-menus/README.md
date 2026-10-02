# moOde UI — larger menus

Makes the moOde WebUI **menus** follow the native **Font size** setting and
scale them a bit larger than the page body. Nothing else in the UI changes.

## Why menus don't scale on their own

moOde scales its UI through one CSS variable, `--pbfont`. The Preferences →
Font size setting (`Smaller … X-Large`) writes it on `<body>`:

```js
// js/playerlib.js
function setFontSize() {
    var sizeFactor = getKeyOrValue('value', SESSION.json['font_size']);
    document.body.style.setProperty('--pbfont', 'calc(' + sizeFactor + 'rem + 1vmin)');
}
```

But `--pbfont` is consumed by a **single rule**:

```css
#content { font-size: var(--pbfont); }
```

Everything inside `#content` grows — and the menus are **outside** it:

| Menu | DOM container | In `#content`? |
|---|---|---|
| Playback context menu (⋯), queue/db menus | `#context-menus` | no |
| Dashboard "m" menu | `#panel-header` | no |
| Library dropdown | `#viewswitch` | yes, but its buttons carry a fixed size |

So they stay at the hard-coded sizes (`1em`, bumped to `1.15em` by a media
query at 800×480) no matter what Font size you pick.

## What this does

Appends one small, clearly-marked block at the end of the served stylesheet
(`/var/www/css/styles.min.css`) that re-points the menu selectors — and only
those — at `var(--pbfont)` with a multiplier:

```css
.dropdown-menu>li>a,
#context-menus .dropdown-menu>li>a,
#panel-header .dropdown-menu>li>a,
.viewswitch .btn:not(#viewswitch-search),
#dashboard-menu .dropdown-menu>li>a {
    font-size: calc(var(--pbfont, 12px) * 1.35) !important;
    line-height: 2.35em !important;
    ...
}
```

* Cascade order makes it win; `!important` keeps the media-query sizes from
  overriding it.
* Because it uses `var(--pbfont)`, the menus now **follow Font size** (choose
  X-Large and both the page and the menus grow).
* The multiplier (default `1.35`, `--scale N`) makes the menus a bit bigger
  than the body text, which is what the small 800×480 display needs.
* Menu-only selectors: no other element is touched.

A pristine copy of the stylesheet is kept in
`/usr/local/jukebox-menu-font/styles.min.css.orig` and restored on uninstall.

## Persistence

`styles.min.css` belongs to the `moode-player` package: an update or a moOde
rebuild regenerates it and would drop the block. `jukebox-menu-font-guard.path`
watches the file and re-runs `apply` when it changes; the service is also
enabled at boot.

## Install

From this directory (ships and runs over SSH):

```sh
./deploy.sh --host moode@<host> install
```

or on the Pi as root:

```sh
sudo ./jukebox-menu-font.sh install [--scale 1.35]
```

Other commands: `verify`, `apply`, `status`, `uninstall`.

Change the size later:

```sh
sudo /usr/local/jukebox-menu-font/jukebox-menu-font.sh install --scale 1.5
```

The kiosk caches the stylesheet; the installer restarts `localdisplay.service`.
A reboot is the safest way to be sure.

## Layout

```
jukebox-menu-font.sh   # installer / verify / status / uninstall + guard target
deploy.sh              # ship and run it over SSH
README.md              # this file
```
