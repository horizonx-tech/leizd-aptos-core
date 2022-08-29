#[test_only]
module leizd::test_initializer {

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::collateral;
    #[test_only]
    use leizd::collateral_only;
    #[test_only]
    use leizd::debt;

    // initializer.move (avoid the dependency cycle)
    #[test_only]
    public fun register<C>(account: &signer) {
        managed_coin::register<C>(account);
        collateral::register<C>(account);
        collateral_only::register<C>(account);
        debt::register<C>(account);
    }
}