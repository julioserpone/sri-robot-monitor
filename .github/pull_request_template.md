## Descripción

<!-- Qué hace este PR y por qué. Enlaza el issue si existe. -->

Closes #

## Tipo de cambio

- [ ] Funcionalidad nueva (`feat`)
- [ ] Corrección de error (`fix`)
- [ ] Documentación (`docs`)
- [ ] Pruebas (`test`)
- [ ] Mantenimiento (`chore`)

## Qué cambia

<!-- Lista corta y concreta. Si toca la UI, describe la pantalla. -->

## Cómo probarlo

<!-- Pasos para quien revisa. Si aplica: cuenta de AWS de prueba, función, período. -->

1.
2.
3.

## Checklist

- [ ] Compila sin warnings nuevos:
      `xcodebuild -project SriRobotMonitor.xcodeproj -scheme SriRobotMonitor -configuration Debug -destination 'platform=macOS' build`
- [ ] La suite pasa:
      `xcodebuild -project SriRobotMonitor.xcodeproj -scheme SriRobotMonitor -configuration Debug -destination 'platform=macOS' test`
- [ ] Añadí pruebas para lo nuevo (o expliqué por qué no aplica)
- [ ] Actualicé `CHANGELOG.md` si el cambio es visible para quien usa la app
- [ ] No incluí credenciales, tokens, log groups de cuentas ajenas ni datos de contribuyentes
- [ ] Si toqué AWS (firma, permisos, payload), lo verifiqué contra la documentación oficial

## Uso de IA

- [ ] No usé IA
- [ ] Usé IA y revisé cada línea
- [ ] Usé IA para parte del trabajo (detalla abajo)

<!-- Qué herramienta, para qué partes y qué no pudiste verificar. Ver docs/USO_IA.md -->

## Capturas

<!-- Antes / después si cambia la interfaz. Arrastra las imágenes aquí. -->

## Notas para quien revisa

<!-- Decisiones discutibles, alternativas descartadas, riesgos conocidos. -->
