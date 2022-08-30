module leizd::initializer {

    use aptos_framework::managed_coin;
    use leizd::repository;
    use leizd::system_status;
    use leizd::collateral;
    use leizd::collateral_only;
    use leizd::debt;
    use leizd::trove;
    use leizd::stability_pool;

    public entry fun initialize(owner: &signer) {
        system_status::initialize(owner);
        repository::initialize(owner);
        trove::initialize(owner);
        stability_pool::initialize(owner);
    }

    public entry fun register<C>(account: &signer) {
        managed_coin::register<C>(account);
        collateral::register<C>(account);
        collateral_only::register<C>(account);
        debt::register<C>(account);
    }
}