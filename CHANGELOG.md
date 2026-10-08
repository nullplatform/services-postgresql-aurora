# Changelog

## [0.4.0](https://github.com/nullplatform/services-postgresql-aurora/compare/v0.3.5...v0.4.0) (2026-10-08)


### Features

* run the worker images as a non-root user ([963feb7](https://github.com/nullplatform/services-postgresql-aurora/commit/963feb751b4202fcdec25e0dcfbff420a64be2f0))
* run the worker images as a non-root user ([6bf6119](https://github.com/nullplatform/services-postgresql-aurora/commit/6bf611953c7e8ecbf4a3f82c4c085b50c5baceaf))


### Bug Fixes

* hand HOME to the runtime user ([bdff831](https://github.com/nullplatform/services-postgresql-aurora/commit/bdff83176945f8db9908993a07caccab701ddefe))

## [0.3.5](https://github.com/nullplatform/services-postgresql-aurora/compare/v0.3.4...v0.3.5) (2026-10-02)


### Bug Fixes

* **deps:** bump aws-actions/configure-aws-credentials from 4 to 6 ([#19](https://github.com/nullplatform/services-postgresql-aurora/issues/19)) ([c3ba782](https://github.com/nullplatform/services-postgresql-aurora/commit/c3ba78232bfbdcd36675b98e84e6c1ba36408821))

## [0.3.4](https://github.com/nullplatform/services-postgresql-aurora/compare/v0.3.3...v0.3.4) (2026-10-02)


### Bug Fixes

* **deps:** bump docker/setup-buildx-action from 3 to 4 ([#20](https://github.com/nullplatform/services-postgresql-aurora/issues/20)) ([dc466e8](https://github.com/nullplatform/services-postgresql-aurora/commit/dc466e83494b6d10e140caf662383b0d1d022689))
* **deps:** bump docker/setup-qemu-action from 3 to 4 ([#18](https://github.com/nullplatform/services-postgresql-aurora/issues/18)) ([1cc6e48](https://github.com/nullplatform/services-postgresql-aurora/commit/1cc6e482349a3167bfe70b3bb38b7670e58b722f))

## [0.3.3](https://github.com/nullplatform/services-postgresql-aurora/compare/v0.3.2...v0.3.3) (2026-10-02)


### Bug Fixes

* **deps:** update dependency opentofu/opentofu to v1.13.1 ([#27](https://github.com/nullplatform/services-postgresql-aurora/issues/27)) ([c60e1d5](https://github.com/nullplatform/services-postgresql-aurora/commit/c60e1d57295b222ef4aa9174898aad5a50794877))

## [0.3.2](https://github.com/nullplatform/services-postgresql-aurora/compare/v0.3.1...v0.3.2) (2026-10-01)


### Bug Fixes

* **deps:** bump nullplatform/scopes/worker-bridge from 1.1.1 to 2.0.1 ([e1d565f](https://github.com/nullplatform/services-postgresql-aurora/commit/e1d565f7e664e9487d9f09adeba7ca0b2c873c7c))
* **deps:** bump nullplatform/scopes/worker-bridge from 1.1.1 to 2.0.1 ([ab4fb62](https://github.com/nullplatform/services-postgresql-aurora/commit/ab4fb628732a4f8875a1c50155259dbea4d4beb7))

## [0.3.1](https://github.com/nullplatform/services-postgresql-aurora/compare/v0.3.0...v0.3.1) (2026-09-21)


### Bug Fixes

* **deps:** bump actions/checkout from 4 to 7 ([#21](https://github.com/nullplatform/services-postgresql-aurora/issues/21)) ([5037623](https://github.com/nullplatform/services-postgresql-aurora/commit/50376239b7645720c14b7453505bc5bf0405107e))

## [0.3.0](https://github.com/nullplatform/services-postgresql-aurora/compare/v0.2.0...v0.3.0) (2026-09-18)


### Features

* dependabot for base image bumps ([bb2d5c7](https://github.com/nullplatform/services-postgresql-aurora/commit/bb2d5c7fd6725be814c96a9e465cf8cbfff3a05a))
* dependabot for base image bumps ([a0b3cbd](https://github.com/nullplatform/services-postgresql-aurora/commit/a0b3cbd061e696ddaf3204b316e80ebe111f7c5b))


### Bug Fixes

* **ci:** auto-merge the release PR from workflow_run; Dependabot commits as fix(deps) ([4e54c20](https://github.com/nullplatform/services-postgresql-aurora/commit/4e54c20bb988bdbfcadbf1c07288db12f3e796a6))
* **deps:** bump nullplatform/scopes/worker-bridge from 1.0.0 to 1.1.1 ([9bfdc0a](https://github.com/nullplatform/services-postgresql-aurora/commit/9bfdc0ac6509a8c69e34b1378b410356e1ef625f))

## [0.2.0](https://github.com/nullplatform/services-postgresql-aurora/compare/v0.1.1...v0.2.0) (2026-09-14)


### Features

* publish worker images for both Aurora services ([776ad37](https://github.com/nullplatform/services-postgresql-aurora/commit/776ad37cc3c9ec9bf10df73cfe31b0dd14b227b3))
* publish worker images for both Aurora services ([8bb1aba](https://github.com/nullplatform/services-postgresql-aurora/commit/8bb1aba4f8233dd8fa0b05a7719da97f2eff5af6))

## [0.1.1](https://github.com/nullplatform/services-postgresql-aurora/compare/v0.1.0...v0.1.1) (2026-08-24)


### Bug Fixes

* add KMS IAM policy to the aurora-postgres-server permissions role ([ecfb57f](https://github.com/nullplatform/services-postgresql-aurora/commit/ecfb57ff39a138864a138c1f3bcfe22655f84c7e))

## [0.1.0](https://github.com/nullplatform/services-postgresql-aurora/compare/v0.0.2...v0.1.0) (2026-08-24)


### Features

* **aurora-postgres-server:** make Secrets Manager encryption key configurable ([dfe1806](https://github.com/nullplatform/services-postgresql-aurora/commit/dfe18062427ca2420a48d0130bf52eb5540094a5))


### Bug Fixes

* **aurora-postgres-db:** encrypt the app secret with a customer managed key ([8d00ae8](https://github.com/nullplatform/services-postgresql-aurora/commit/8d00ae815424d04a3d1ff82bd8f975a9bdc2ea9c))
* **aurora-postgres-db:** store app-level credentials in Secrets Manager ([c2e058b](https://github.com/nullplatform/services-postgresql-aurora/commit/c2e058b1e945c5b7eaeb32b92c8fa08f9cf9e6b0))
* **aurora-postgres-server:** grant KMS access so secret_kms_key_id works ([27ac6d4](https://github.com/nullplatform/services-postgresql-aurora/commit/27ac6d415e84e98c00e5f0287c942aefab677680))

## [0.0.2](https://github.com/nullplatform/services-postgresql-aurora/compare/0.0.1...v0.0.2) (2026-07-28)


### Bug Fixes

* add instance_class enum to render as a dropdown in the nullplatform UI ([130da55](https://github.com/nullplatform/services-postgresql-aurora/commit/130da55254e7bd88046ff89d1e5fe0e33e0253b8))
* add rds:DescribeGlobalClusters to aurora-postgres-server IAM policy ([7441ede](https://github.com/nullplatform/services-postgresql-aurora/commit/7441ede5893836c9be8c8dbc729bb36df2f68a91))
* use a customer managed KMS key for Aurora storage encryption ([5f71cc7](https://github.com/nullplatform/services-postgresql-aurora/commit/5f71cc72192de9f1348dabc801ef2833c9b0ab82))
