module leizd_aptos_entry::initializer {

    use aptos_framework::managed_coin;
    use leizd_aptos_common::system_status;
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::trove;
    use leizd_aptos_external::price_oracle;
    use leizd_aptos_central_liquidity_pool::central_liquidity_pool;
    use leizd_aptos_treasury::treasury;
    use leizd_aptos_logic::risk_factor;
    use leizd_aptos_core::interest_rate;
    use leizd_aptos_core::pool_status;
    use leizd_aptos_core::pool_manager;

    /// Called only once by the owner.
    public entry fun initialize(owner: &signer) {
        system_status::initialize(owner);
        risk_factor::initialize(owner);
        treasury::initialize(owner);
        trove::initialize(owner);
        price_oracle::initialize(owner);
        interest_rate::initialize(owner);
        pool_status::initialize(owner);
        pool_manager::initialize(owner);
        central_liquidity_pool::initialize(owner);
        permission::initialize(owner);
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
    #[test(owner = @leizd_aptos_entry)]
    fun test_initialize(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
    }
    #[test(owner = @leizd_aptos_entry)]
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