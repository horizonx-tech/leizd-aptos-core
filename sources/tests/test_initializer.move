#[test_only]
module leizd::test_initializer {

    #[test_only]
    use aptos_framework::managed_coin;

    // initializer.move (avoid the dependency cycle)
    public fun register<C>(account: &signer) {
        managed_coin::register<C>(account);
    }
}