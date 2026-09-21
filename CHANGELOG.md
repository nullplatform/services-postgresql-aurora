# Changelog

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
