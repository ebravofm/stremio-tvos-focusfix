# stremio-tvos-focusfix

Tweak (dylib) para investigar un bug de foco en la biblioteca de Stremio para tvOS:
al mover el foco, se oye el cambio de celda pero la imagen no cambia y la app se cuelga.

`StremioFocusDiag.m` engancha `didUpdateFocusInContext` de la grilla y muestra en pantalla
los ultimos eventos de foco, el `contentOffset` y si el hilo principal se bloquea.

No contiene codigo, binarios ni recursos de Stremio. Se compila en GitHub Actions y se
inyecta con Sideloadly (Advanced Options > Inject dylibs).
