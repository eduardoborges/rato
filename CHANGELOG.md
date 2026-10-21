# Changelog

## [0.2.0](https://github.com/eduardoborges/rato/compare/v0.1.2...v0.2.0) (2026-10-21)


### Features

* learn the battery curve from the mouse instead of G HUB's file ([b74f6f8](https://github.com/eduardoborges/rato/commit/b74f6f84f20ca03e0db33e705d824372bbdae9d3))
* read the mouse's own name and model id ([a32a9ce](https://github.com/eduardoborges/rato/commit/a32a9ce02a4c73887655e8bdd098f76c4044d2c6))
* replace the menu with a SwiftUI panel ([698f4cf](https://github.com/eduardoborges/rato/commit/698f4cf55e1305e430f955aee0f20a3379eae6bf))
* show a photo of the mouse from Logitech's site ([e736aa2](https://github.com/eduardoborges/rato/commit/e736aa227daa20ea11da17a29d30269a83016bfe))


### Bug Fixes

* don't show a corrupted profile in the panel ([0ef7f32](https://github.com/eduardoborges/rato/commit/0ef7f32bc21976215524111a12325e8ebdc624c4))
* keep the selected option readable without Liquid Glass ([38fe65f](https://github.com/eduardoborges/rato/commit/38fe65f8f8d7dc691ce43cb3928eb65ac4b33ed8))
* open the panel with no control in focus ([0005a03](https://github.com/eduardoborges/rato/commit/0005a0313167c57af0a1f0a6ed33bd349c40b16b))
* print HID++ feature ids as 0x0000 in errors ([8fd1185](https://github.com/eduardoborges/rato/commit/8fd11854687309f0aafdbf5b7c2214ee9f96cb1b))
* send one HID++ request at a time on each device ([e212b8b](https://github.com/eduardoborges/rato/commit/e212b8bf269321c610b23551e1d86706de3c43a9))
* show the feature id, not its index, when the mouse doesn't answer ([bf472ae](https://github.com/eduardoborges/rato/commit/bf472ae0f1272e9e91b956cd9eda5fe2ddb37527))

## [0.1.2](https://github.com/eduardoborges/rato/compare/v0.1.1...v0.1.2) (2026-10-20)


### Bug Fixes

* keep the last battery reading when a read fails ([ecb0e13](https://github.com/eduardoborges/rato/commit/ecb0e13ccb8c98231ff42a39dd5173296c003138))

## [0.1.1](https://github.com/eduardoborges/rato/compare/v0.1.0...v0.1.1) (2026-10-20)


### Bug Fixes

* find a mouse that was asleep when the app opened ([af409fd](https://github.com/eduardoborges/rato/commit/af409fd57004983744f5fd48ba9f2118bc83366c))

## 0.1.0 (2026-10-20)


### Features

* battery time left from the G HUB power model ([5e1b98b](https://github.com/eduardoborges/rato/commit/5e1b98b541fcdcf378e93a9f6f517c9df18b202f))
* menu bar app for Logitech mice over HID++ ([c0e8cd0](https://github.com/eduardoborges/rato/commit/c0e8cd0f51c7450b77a1f7f739555dc310073e03))
* package Rato.app with an Icon Composer icon ([17194b1](https://github.com/eduardoborges/rato/commit/17194b1b2acbea2ffb629737004fc5644aed1fb3))


### Bug Fixes

* ask for Input Monitoring when running as an app ([4943e22](https://github.com/eduardoborges/rato/commit/4943e22bb5d40b662fa4de51918663450e9fd39e))
* flush logs line by line outside a terminal ([9a23584](https://github.com/eduardoborges/rato/commit/9a23584a175920306408f02e59353b428ee07349))
* skip the time estimate when the power model has no blocks ([1767669](https://github.com/eduardoborges/rato/commit/176766970cf23cfcdb2c56aca98102d6f8af32c5))
