module leizd::initializer {

    use aptos_framework::managed_coin;
    use leizd_aptos_common::system_status;
    use leizd_aptos_trove::trove_manager;
    use leizd_aptos_treasury::treasury;
    use leizd::risk_factor;
    use leizd::pool_manager;
    use leizd::stability_pool;

    /// Called only once by the owner.
    public entry fun initialize(owner: &signer) {
        system_status::initialize(owner);
        risk_factor::initialize(owner);
        treasury::initialize(owner);
        trove_manager::initialize(owner);
        pool_manager::initialize(owner);
        stability_pool::initialize(owner);
    }

    public entry fun register<C>(account: &signer) {
        managed_coin::register<C>(account);
    }

    #[test_only]
    use std::signer;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    struct TestCoin {}
    #[test(owner = @leizd)]
    fun test_initialize(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
    }
    #[test(owner = @leizd)]
    #[expected_failure]
    fun test_initialize_twice(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        initialize(owner);
    }
    #[test(account = @0x111)]
    #[expected_failure]
    fun test_initialize_with_not_owner(account: &signer) {
        account::create_account_for_test(signer::address_of(account));
        initialize(account);
    }
    #[test(account = @0x111)]
    fun test_register(account: &signer) {
        account::create_account_for_test(signer::address_of(account));
        register<TestCoin>(account);
    }
    #[test(account = @0x111)]
    #[expected_failure]
    fun test_register_twice(account: &signer) {
        account::create_account_for_test(signer::address_of(account));
        register<TestCoin>(account);
        register<TestCoin>(account);
    }
}