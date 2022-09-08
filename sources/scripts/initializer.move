module leizd::initializer {

    use aptos_framework::managed_coin;
    use leizd::repository;
    use leizd::system_status;
    use leizd::collateral;
    use leizd::collateral_only;
    use leizd::debt;
    use leizd::trove_manager;
    use leizd::stability_pool;

    public entry fun initialize(owner: &signer) {
        system_status::initialize(owner);
        repository::initialize(owner);
        trove_manager::initialize(owner);
        stability_pool::initialize(owner);
    }

    public entry fun register<C>(account: &signer) {
        managed_coin::register<C>(account);
        collateral::register<C>(account);
        collateral_only::register<C>(account);
        debt::register<C>(account);
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