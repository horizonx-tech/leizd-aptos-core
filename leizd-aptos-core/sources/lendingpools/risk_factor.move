module leizd::risk_factor {

    use std::error;
    use std::signer;
    use std::string;
    use aptos_std::event;
    use aptos_std::type_info;
    use aptos_framework::account;
    use aptos_framework::table;
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::usdz::{USDZ};

    friend leizd::asset_pool;

    const PRECISION: u64 = 1000000000;
    const DEFAULT_ENTRY_FEE: u64 = 1000000000 / 1000 * 5; // 0.5%
    const DEFAULT_SHARE_FEE: u64 = 1000000000 / 1000 * 5; // 0.5%
    const DEFAULT_LIQUIDATION_FEE: u64 = 1000000000 / 1000 * 5; // 0.5%
    const DEFAULT_LTV: u64 = 1000000000 / 100 * 50; // 50%
    const DEFAULT_THRESHOLD: u64 = 1000000000 / 100 * 70 ; // 70%
    const SHADOW_LTV: u64 = 1000000000 / 100 * 100; // 100%
    const SHADOW_LT: u64 = 1000000000 / 100 * 100; // 100%

    const EALREADY_ADDED_ASSET: u64 = 1;
    const EINVALID_THRESHOLD: u64 = 2;
    const EINVALID_LTV: u64 = 3;
    const EINVALID_ENTRY_FEE: u64 = 4;
    const EINVALID_SHARE_FEE: u64 = 5;
    const EINVALID_LIQUIDATION_FEE: u64 = 6;

    struct ProtocolFees has key, drop {
        entry_fee: u64, // One time protocol fee for opening a borrow position
        share_fee: u64, // Protocol revenue share in interest
        liquidation_fee: u64, // Protocol share in liquidation profit
    }

    struct Config has key {
        ltv: table::Table<string::String,u64>, // Loan To Value
        lt: table::Table<string::String,u64>, // Liquidation Threshold
    }

    // Events
    struct UpdateProtocolFeesEvent has store, drop {
        caller: address,
        entry_fee: u64,
        share_fee: u64,
        liquidation_fee: u64,
    }

    struct UpdateConfigEvent has store, drop {
        caller: address,
        key: string::String,
        ltv: u64,
        lt: u64,
    }

    struct RepositoryEventHandle has key, store {
        update_protocol_fees_event: event::EventHandle<UpdateProtocolFeesEvent>,
    }

    struct RepositoryAssetEventHandle has key, store {
        update_config_event: event::EventHandle<UpdateConfigEvent>,
    }

    public entry fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        assert_liquidation_threshold(DEFAULT_LTV, DEFAULT_THRESHOLD);

        let ltv = table::new<string::String,u64>();
        let lt = table::new<string::String,u64>();
        let usdz_name = type_info::type_name<USDZ>();
        table::add<string::String,u64>(&mut ltv, usdz_name, SHADOW_LTV);
        table::add<string::String,u64>(&mut lt, usdz_name, SHADOW_LT);
        move_to(owner, Config {
            ltv: ltv,
            lt: lt,
        });
        move_to(owner, ProtocolFees {
            entry_fee: DEFAULT_ENTRY_FEE,
            share_fee: DEFAULT_SHARE_FEE,
            liquidation_fee: DEFAULT_LIQUIDATION_FEE
        });
        move_to(owner, RepositoryEventHandle {
            update_protocol_fees_event: account::new_event_handle<UpdateProtocolFeesEvent>(owner),
        });
        move_to(owner, RepositoryAssetEventHandle {
            update_config_event: account::new_event_handle<UpdateConfigEvent>(owner),
        });
    }

    public(friend) fun new_asset<C>(account: &signer) acquires Config, RepositoryAssetEventHandle {
        new_asset_internal<C>(account);
    }
    fun new_asset_internal<C>(_account: &signer) acquires Config, RepositoryAssetEventHandle {
        let owner_address = permission::owner_address();

        let config_ref = borrow_global_mut<Config>(owner_address);
        let name = type_info::type_name<C>();
        assert!(!table::contains<string::String, u64>(&config_ref.ltv, name), error::invalid_argument(EALREADY_ADDED_ASSET));
        table::upsert<string::String,u64>(&mut config_ref.ltv, name, DEFAULT_LTV);
        table::upsert<string::String,u64>(&mut config_ref.lt, name, DEFAULT_THRESHOLD);
        event::emit_event<UpdateConfigEvent>(
            &mut borrow_global_mut<RepositoryAssetEventHandle>(owner_address).update_config_event,
            UpdateConfigEvent {
                caller: owner_address,
                key: name,
                ltv: DEFAULT_LTV,
                lt: DEFAULT_THRESHOLD,
            }
        )
    }

    public entry fun update_protocol_fees(owner: &signer, fees: ProtocolFees) acquires ProtocolFees, RepositoryEventHandle {
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);

        assert!(fees.entry_fee < PRECISION, error::invalid_argument(EINVALID_ENTRY_FEE));
        assert!(fees.share_fee < PRECISION, error::invalid_argument(EINVALID_SHARE_FEE));
        assert!(fees.liquidation_fee < PRECISION, error::invalid_argument(EINVALID_LIQUIDATION_FEE));

        let _fees = borrow_global_mut<ProtocolFees>(owner_address);
        _fees.entry_fee = fees.entry_fee;
        _fees.share_fee = fees.share_fee;
        _fees.liquidation_fee = fees.liquidation_fee;
        event::emit_event<UpdateProtocolFeesEvent>(
            &mut borrow_global_mut<RepositoryEventHandle>(owner_address).update_protocol_fees_event,
            UpdateProtocolFeesEvent {
                caller: owner_address,
                entry_fee: fees.entry_fee,
                share_fee: fees.share_fee,
                liquidation_fee: fees.liquidation_fee,
            }
        )
    }

    public entry fun update_config<T>(owner: &signer, new_ltv: u64, new_lt: u64) acquires Config, RepositoryAssetEventHandle {
        permission::assert_owner(signer::address_of(owner));
        let owner_address = signer::address_of(owner);

        let _config = borrow_global_mut<Config>(owner_address);
        let name = type_info::type_name<T>();
        assert_liquidation_threshold(new_ltv, new_lt);

        table::upsert<string::String,u64>(&mut _config.ltv, name, new_ltv);
        table::upsert<string::String,u64>(&mut _config.lt, name, new_lt);
        event::emit_event<UpdateConfigEvent>(
            &mut borrow_global_mut<RepositoryAssetEventHandle>(owner_address).update_config_event,
            UpdateConfigEvent {
                caller: owner_address,
                key: name,
                ltv: new_ltv,
                lt: new_lt,
            }
        )
    }

    fun assert_liquidation_threshold(ltv: u64, lt: u64) {
        assert!(lt <= PRECISION, error::invalid_argument(EINVALID_THRESHOLD));
        assert!(ltv != 0 && ltv <= lt, error::invalid_argument(EINVALID_LTV));
    }

    public fun ltv<C>(): u64 acquires Config {
        let name = type_info::type_name<C>();
        let config = borrow_global<Config>(permission::owner_address());
        *table::borrow<string::String,u64>(&config.ltv, name)
    }

    public fun lt<C>(): u64 acquires Config {
        let name = type_info::type_name<C>();
        lt_of(name)
    }

    public fun lt_of(name: string::String): u64 acquires Config {
        let config = borrow_global<Config>(permission::owner_address());
        *table::borrow<string::String,u64>(&config.lt, name)
    } 

    public fun lt_of_shadow(): u64 acquires Config {
        let config = borrow_global<Config>(permission::owner_address());
        *table::borrow<string::String,u64>(&config.lt, type_info::type_name<USDZ>())
    }

    // about fee
    public fun entry_fee(): u64 acquires ProtocolFees {
        borrow_global<ProtocolFees>(permission::owner_address()).entry_fee
    }
    public fun calculate_entry_fee(value: u64): u64 acquires ProtocolFees {
        calculate_fee_with_round_up(value, entry_fee())
    }
    public fun share_fee(): u64 acquires ProtocolFees {
        borrow_global<ProtocolFees>(permission::owner_address()).share_fee
    }
    public fun calculate_share_fee(value: u64): u64 acquires ProtocolFees {
        calculate_fee_with_round_up(value, share_fee())
    }
    //// for round up
    fun calculate_fee_with_round_up(value: u64, fee: u64): u64 {
        let value_mul_by_fee = value * fee;
        let result = value_mul_by_fee / precision();
        if (value_mul_by_fee % precision() != 0) result + 1 else result
    }

    public fun liquidation_fee(): u64 acquires ProtocolFees {
        borrow_global<ProtocolFees>(permission::owner_address()).liquidation_fee
    }
    public fun calculate_liquidation_fee(value: u64): u64 acquires ProtocolFees {
        value * liquidation_fee() / precision() // round down
    }

    public entry fun precision(): u64 {
        PRECISION
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::test_coin::{Self,WETH};
    #[test_only]
    public fun default_lt(): u64 {
        DEFAULT_THRESHOLD
    }
    #[test_only]
    public fun default_lt_of_shadow(): u64 {
        SHADOW_LT
    }
    #[test_only]
    public fun default_entry_fee(): u64 {
        DEFAULT_ENTRY_FEE
    }
    #[test_only]
    public fun default_share_fee(): u64 {
        DEFAULT_SHARE_FEE
    }
    #[test_only]
    public fun default_liquidation_fee(): u64 {
        DEFAULT_LIQUIDATION_FEE
    }
    #[test_only]
    public fun new_asset_for_test<C>(account: &signer) acquires Config, RepositoryAssetEventHandle {
        new_asset_internal<C>(account);
    }
    #[test(owner = @leizd)]
    public entry fun test_initialize(owner: signer) acquires ProtocolFees, RepositoryEventHandle {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        initialize(&owner);

        let protocol_fees = borrow_global<ProtocolFees>(owner_addr);
        assert!(protocol_fees.entry_fee == DEFAULT_ENTRY_FEE, 0);
        assert!(protocol_fees.share_fee == DEFAULT_SHARE_FEE, 0);
        assert!(protocol_fees.liquidation_fee == DEFAULT_LIQUIDATION_FEE, 0);
        let event_handle = borrow_global<RepositoryEventHandle>(owner_addr);
        assert!(event::counter(&event_handle.update_protocol_fees_event) == 0, 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    public entry fun test_initialize_without_owner(account: signer) {
        initialize(&account);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_update_protocol_fees(owner: signer, account1: signer) acquires Config, ProtocolFees, RepositoryEventHandle, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);

        test_coin::init_weth(&owner);
        initialize(&owner);
        new_asset<WETH>(&owner);
        managed_coin::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);

        let new_protocol_fees = ProtocolFees {
            entry_fee: PRECISION / 1000 * 8, // 0.8%
            share_fee: PRECISION / 1000 * 7, // 0.7%,
            liquidation_fee: PRECISION / 1000 * 6, // 0.6%,
        };
        update_protocol_fees(&owner, new_protocol_fees);
        let fees = borrow_global<ProtocolFees>(permission::owner_address());
        assert!(fees.entry_fee == PRECISION / 1000 * 8, 0);
        assert!(fees.share_fee == PRECISION / 1000 * 7, 0);
        assert!(fees.liquidation_fee == PRECISION / 1000 * 6, 0);
        let event_handle = borrow_global<RepositoryEventHandle>(owner_addr);
        assert!(event::counter(&event_handle.update_protocol_fees_event) == 1, 0);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_update_protocol_fees_when_share_fee_is_greater_than_100(owner: signer) acquires Config, ProtocolFees, RepositoryEventHandle, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        initialize(&owner);
        new_asset<WETH>(&owner);

        let new_protocol_fees = ProtocolFees {
            entry_fee: PRECISION / 1000 * 8, // 0.8%
            share_fee: PRECISION,
            liquidation_fee: PRECISION / 1000 * 6, // 0.6%,
        };
        update_protocol_fees(&owner, new_protocol_fees);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_update_protocol_fees_when_liquidation_fee_is_greater_than_100(owner: signer) acquires Config, ProtocolFees, RepositoryEventHandle, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        initialize(&owner);
        new_asset<WETH>(&owner);

        let new_protocol_fees = ProtocolFees {
            entry_fee: PRECISION / 1000 * 8, // 0.8%
            share_fee: PRECISION / 1000 * 7, // 0.7%,
            liquidation_fee: PRECISION,
        };
        update_protocol_fees(&owner, new_protocol_fees);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65540)]
    public entry fun test_update_protocol_fees_when_entry_fee_is_greater_than_100(owner: signer) acquires Config, ProtocolFees, RepositoryEventHandle, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        initialize(&owner);
        new_asset<WETH>(&owner);

        let new_protocol_fees = ProtocolFees {
            entry_fee: PRECISION,
            share_fee: PRECISION / 1000 * 7, // 0.7%,
            liquidation_fee: PRECISION / 1000 * 6, // 0.6%,
        };
        update_protocol_fees(&owner, new_protocol_fees);
    }
    #[test_only]
    struct TestAsset {}
    #[test(owner = @leizd)]
    public entry fun test_new_asset(owner: &signer) acquires Config, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        new_asset<TestAsset>(owner);

        let name = type_info::type_name<TestAsset>();
        let config = borrow_global<Config>(owner_addr);
        let new_ltv = table::borrow<string::String,u64>(&config.ltv, name);
        let new_lt = table::borrow<string::String,u64>(&config.lt, name);

        assert!(*new_ltv == DEFAULT_LTV, 0);
        assert!(*new_lt == DEFAULT_THRESHOLD, 0);
    }

    #[test(owner = @leizd, account = @0x111)]
    public entry fun test_new_asset_without_owner(owner: &signer, account: &signer) acquires Config, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        new_asset<TestAsset>(account);

        let key = type_info::type_name<TestAsset>();
        let config = borrow_global<Config>(owner_addr);
        let new_ltv = table::borrow<string::String,u64>(&config.ltv, key);
        let new_lt = table::borrow<string::String,u64>(&config.lt, key);

        assert!(*new_ltv == DEFAULT_LTV, 0);
        assert!(*new_lt == DEFAULT_THRESHOLD, 0);
    }
    #[test(owner = @leizd)]
    #[expected_failure(abort_code = 65537)]
    public entry fun test_new_asset_twice(owner: &signer) acquires Config, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        new_asset<TestAsset>(owner);
        new_asset<TestAsset>(owner);
    }
    #[test(owner=@leizd)]
    public entry fun test_update_config(owner: &signer) acquires Config, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        new_asset<TestAsset>(owner);

        let name = type_info::type_name<TestAsset>();
        update_config<TestAsset>(owner, PRECISION / 100 * 70, PRECISION / 100 * 90);
        let config = borrow_global<Config>(permission::owner_address());
        let new_ltv = table::borrow<string::String,u64>(&config.ltv, name);
        let new_lt = table::borrow<string::String,u64>(&config.lt, name);
        assert!(*new_ltv == PRECISION / 100 * 70, 0);
        assert!(*new_lt == PRECISION / 100 * 90, 0);
        assert!(ltv<TestAsset>() == PRECISION / 100 * 70, 0);
        assert!(lt<TestAsset>() == PRECISION / 100 * 90, 0);
        assert!(lt_of(name) == PRECISION / 100 * 90, 0);
        let event_handle = borrow_global<RepositoryAssetEventHandle>(owner_addr);
        assert!(event::counter(&event_handle.update_config_event) == 2, 0);
    }
    #[test(owner=@leizd)]
    public entry fun test_update_config_with_usdz(owner: &signer) acquires Config, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);

        update_config<USDZ>(owner, PRECISION / 100 * 20, PRECISION / 100 * 40);
        let config = borrow_global<Config>(permission::owner_address());
        let name = type_info::type_name<USDZ>();
        let new_ltv = table::borrow<string::String,u64>(&config.ltv, name);
        let new_lt = table::borrow<string::String,u64>(&config.lt, name);
        assert!(*new_ltv == PRECISION / 100 * 20, 0);
        assert!(*new_lt == PRECISION / 100 * 40, 0);
        assert!(ltv<USDZ>() == PRECISION / 100 * 20, 0);
        assert!(lt<USDZ>() == PRECISION / 100 * 40, 0);
        assert!(lt_of(name) == PRECISION / 100 * 40, 0);
        assert!(lt_of_shadow() == PRECISION / 100 * 40, 0);
        let event_handle = borrow_global<RepositoryAssetEventHandle>(owner_addr);
        assert!(event::counter(&event_handle.update_config_event) == 1, 0);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65538)]
    public entry fun test_update_config_when_lt_is_greater_than_100(owner: &signer) acquires Config, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        new_asset<TestAsset>(owner);
        update_config<TestAsset>(owner, 1, PRECISION + 1);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_update_config_when_ltv_is_0(owner: &signer) acquires Config, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        new_asset<TestAsset>(owner);
        update_config<TestAsset>(owner, 0, PRECISION);
    }
    #[test(owner=@leizd)]
    public entry fun test_update_config_when_ltv_is_equal_to_lt(owner: &signer) acquires Config, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        new_asset<TestAsset>(owner);
        update_config<TestAsset>(owner, PRECISION / 100 * 50, PRECISION / 100 * 50);
        assert!(ltv<TestAsset>() == PRECISION / 100 * 50, 0);
        assert!(lt<TestAsset>() == PRECISION / 100 * 50, 0);
    }
    #[test(owner = @leizd)]
    fun test_calculate_entry_fee(owner: &signer) acquires ProtocolFees {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);

        // Prerequisite
        assert!(entry_fee() == default_entry_fee(), 0);

        // Execute
        assert!(calculate_entry_fee(100000) == 500, 0);
        assert!(calculate_entry_fee(100001) == 501, 0);
        assert!(calculate_entry_fee(99999) == 500, 0);
        assert!(calculate_entry_fee(200) == 1, 0);
        assert!(calculate_entry_fee(199) == 1, 0);
        assert!(calculate_entry_fee(1) == 1, 0);
        assert!(calculate_entry_fee(0) == 0, 0);
    }
    #[test(owner = @leizd)]
    fun test_calculate_share_fee(owner: &signer) acquires ProtocolFees {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);

        // Prerequisite
        assert!(share_fee() == default_share_fee(), 0);

        // Execute
        assert!(calculate_share_fee(100000 + 1) == 501, 0);
        assert!(calculate_share_fee(100000) == 500, 0);
        assert!(calculate_share_fee(100000 - 1) == 500, 0);
        assert!(calculate_share_fee(99800 + 1) == 500, 0);
        assert!(calculate_share_fee(99800) == 499, 0);
        assert!(calculate_share_fee(99800 - 1) == 499, 0);
        assert!(calculate_share_fee(200) == 1, 0);
        assert!(calculate_share_fee(199) == 1, 0);
        assert!(calculate_share_fee(1) == 1, 0);
        assert!(calculate_share_fee(0) == 0, 0);
    }
        #[test(owner = @leizd)]
    fun test_calculate_liquidation_fee(owner: &signer) acquires ProtocolFees {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);

        // Prerequisite
        assert!(liquidation_fee() == default_liquidation_fee(), 0);

        // Execute
        assert!(calculate_liquidation_fee(100000) == 500, 0);
        assert!(calculate_liquidation_fee(100001) == 500, 0);
        assert!(calculate_liquidation_fee(99999) == 499, 0);
        assert!(calculate_liquidation_fee(200) == 1, 0);
        assert!(calculate_liquidation_fee(199) == 0, 0);
        assert!(calculate_liquidation_fee(1) == 0, 0);
        assert!(calculate_liquidation_fee(0) == 0, 0);
    }
}
