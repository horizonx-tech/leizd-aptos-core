module leizd::repository {

    use std::signer;
    use std::string;
    use aptos_std::event;
    use aptos_std::type_info;
    use aptos_framework::account;
    use aptos_framework::table;
    use leizd::permission;
    use leizd::usdz::{USDZ};

    const PRECISION: u64 = 1000000000;
    const DEFAULT_ENTRY_FEE: u64 = 1000000000 / 1000 * 5; // 0.5%
    const DEFAULT_SHARE_FEE: u64 = 1000000000 / 1000 * 5; // 0.5%
    const DEFAULT_LIQUIDATION_FEE: u64 = 1000000000 / 1000 * 5; // 0.5%
    const DEFAULT_LTV: u64 = 1000000000 / 100 * 50; // 50%
    const DEFAULT_THRESHOLD: u64 = 1000000000 / 100 * 70 ; // 70%

    const E_INVALID_THRESHOLD: u64 = 1;
    const E_INVALID_LTV: u64 = 2;
    const E_INVALID_ENTRY_FEE: u64 = 3;
    const E_INVALID_SHARE_FEE: u64 = 4;
    const E_INVALID_LIQUIDATION_FEE: u64 = 5;

    struct ProtocolFees has key, drop {
        entry_fee: u64, // One time protocol fee for opening a borrow position
        share_fee: u64, // Protocol revenue share in interest
        liquidation_fee: u64, // Protocol share in liquidation profit
    }

    struct Config has key {
        ltv: table::Table<string::String,u64>, // Loan To Value
        lt: table::Table<string::String,u64>, // Liquidation Threshold
    }

    struct UpdateProtocolFeesEvent has store, drop {
        caller: address,
        entry_fee: u64,
        share_fee: u64,
        liquidation_fee: u64,
    }

    struct UpdateConfigEvent has store, drop {
        caller: address,
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
        assert_liquidation_threashold(DEFAULT_LTV, DEFAULT_THRESHOLD);

        let ltv = table::new<string::String,u64>();
        let lt = table::new<string::String,u64>();
        let usdz_name = type_info::type_name<USDZ>();
        table::add<string::String,u64>(&mut ltv, usdz_name, PRECISION / 100 * 90);
        table::add<string::String,u64>(&mut lt, usdz_name, PRECISION / 100 * 95);
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

    public entry fun new_asset<C>(owner: &signer) acquires Config {
        permission::assert_owner(signer::address_of(owner));

        let config_ref = borrow_global_mut<Config>(@leizd);
        let name = type_info::type_name<C>();
        table::upsert<string::String,u64>(&mut config_ref.ltv, name, DEFAULT_LTV);
        table::upsert<string::String,u64>(&mut config_ref.lt, name, DEFAULT_THRESHOLD);
    }

    public entry fun update_protocol_fees(owner: &signer, fees: ProtocolFees) acquires ProtocolFees, RepositoryEventHandle {
        permission::assert_owner(signer::address_of(owner));
        assert!(fees.entry_fee < PRECISION, E_INVALID_ENTRY_FEE);
        assert!(fees.share_fee < PRECISION, E_INVALID_SHARE_FEE);
        assert!(fees.liquidation_fee < PRECISION, E_INVALID_LIQUIDATION_FEE);

        let _fees = borrow_global_mut<ProtocolFees>(@leizd);
        _fees.entry_fee = fees.entry_fee;
        _fees.share_fee = fees.share_fee;
        _fees.liquidation_fee = fees.liquidation_fee;
        event::emit_event<UpdateProtocolFeesEvent>(
            &mut borrow_global_mut<RepositoryEventHandle>(@leizd).update_protocol_fees_event,
            UpdateProtocolFeesEvent {
                caller: signer::address_of(owner),
                entry_fee: fees.entry_fee,
                share_fee: fees.share_fee,
                liquidation_fee: fees.liquidation_fee,
            }
        )
    }

    public entry fun update_config<T>(owner: &signer, new_ltv: u64, new_lt: u64) acquires Config, RepositoryAssetEventHandle {
        permission::assert_owner(signer::address_of(owner));

        let _config = borrow_global_mut<Config>(@leizd);
        let name = type_info::type_name<T>();
        assert_liquidation_threashold(new_ltv, new_lt);

        table::upsert<string::String,u64>(&mut _config.ltv, name, new_ltv);
        table::upsert<string::String,u64>(&mut _config.lt, name, new_lt);
        event::emit_event<UpdateConfigEvent>(
            &mut borrow_global_mut<RepositoryAssetEventHandle>(@leizd).update_config_event,
            UpdateConfigEvent {
                caller: signer::address_of(owner),
                ltv: new_ltv,
                lt: new_lt,
            }
        )
    }

    fun assert_liquidation_threashold(ltv: u64, lt: u64) {
        assert!(lt <= PRECISION, E_INVALID_THRESHOLD);
        assert!(ltv != 0 && ltv < lt, E_INVALID_LTV);
    }

    public fun entry_fee(): u64 acquires ProtocolFees {
        borrow_global<ProtocolFees>(@leizd).entry_fee
    }

    public fun share_fee(): u64 acquires ProtocolFees {
        borrow_global<ProtocolFees>(@leizd).share_fee
    }

    public fun liquidation_fee(): u64 acquires ProtocolFees {
        borrow_global<ProtocolFees>(@leizd).liquidation_fee
    }

    public fun ltv<C>(): u64 acquires Config {
        let name = type_info::type_name<C>();
        let config = borrow_global<Config>(@leizd);
        *table::borrow<string::String,u64>(&config.ltv, name)
    }

    public fun lt<C>(): u64 acquires Config {
        let name = type_info::type_name<C>();
        lt_of(name)
    }

    public fun lt_of(name: string::String): u64 acquires Config {
        let config = borrow_global<Config>(@leizd);
        *table::borrow<string::String,u64>(&config.lt, name)
    } 

    public entry fun precision(): u64 {
        PRECISION
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::test_coin::{Self,WETH};
    #[test_only]
    public fun default_entry_fee(): u64 {
        DEFAULT_ENTRY_FEE
    }
    #[test_only]
    public fun default_share_fee(): u64 {
        DEFAULT_SHARE_FEE
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
    public entry fun test_update_protocol_fees(owner: signer, account1: signer) acquires Config, ProtocolFees, RepositoryEventHandle {
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
        let fees = borrow_global<ProtocolFees>(@leizd);
        assert!(fees.entry_fee == PRECISION / 1000 * 8, 0);
        assert!(fees.share_fee == PRECISION / 1000 * 7, 0);
        assert!(fees.liquidation_fee == PRECISION / 1000 * 6, 0);
        let event_handle = borrow_global<RepositoryEventHandle>(owner_addr);
        assert!(event::counter(&event_handle.update_protocol_fees_event) == 1, 0);
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
        let event_handle = borrow_global<RepositoryAssetEventHandle>(owner_addr);
        assert!(event::counter(&event_handle.update_config_event) == 0, 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    public entry fun test_new_asset_without_owner(account: &signer) acquires Config {
        new_asset<TestAsset>(account);
    }

    #[test(owner=@leizd)]
    public entry fun test_update_config(owner: &signer) acquires Config, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        new_asset<TestAsset>(owner);

        let name = type_info::type_name<TestAsset>();
        update_config<TestAsset>(owner, PRECISION / 100 * 70, PRECISION / 100 * 90);
        let config = borrow_global<Config>(@leizd);
        let new_ltv = table::borrow<string::String,u64>(&config.ltv, name);
        let new_lt = table::borrow<string::String,u64>(&config.lt, name);
        assert!(*new_ltv == PRECISION / 100 * 70, 0);
        assert!(*new_lt == PRECISION / 100 * 90, 0);
        let event_handle = borrow_global<RepositoryAssetEventHandle>(owner_addr);
        assert!(event::counter(&event_handle.update_config_event) == 1, 0);
    }
}