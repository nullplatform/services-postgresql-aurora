# Changelog

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
