# leizd-aptos-core

```txt
leizd-aptos-core ... lending pools
leizd-aptos-common ... for lending pools
leizd-aptos-lib ... utilities for calculation etc... (independent)
leizd-aptos-trove ... CDP (USDZ)
leizd-aptos-logic ... modules composing lending pools
leizd-aptos-external ... integrator (for oracle etc)
```

## Tips

```bash
for pkg in `ls | grep leizd-aptos`; do aptos move test --package-dir ${pkg}; done
for pkg in `ls | grep leizd-aptos`; do aptos move compile --package-dir ${pkg}; done
```