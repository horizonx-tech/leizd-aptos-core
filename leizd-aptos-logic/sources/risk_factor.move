module leizd_aptos_logic::risk_factor {

    use std::error;
    use std::signer;
    use std::vector;
    use std::string::{Self,String};
    use aptos_std::event;
    use aptos_std::simple_map::{Self,SimpleMap};
    use aptos_framework::account;
    use aptos_framework::table;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd_aptos_lib::i128;
    use leizd_aptos_lib::prb_math;

    //// error_codes
    const EALREADY_ADDED_ASSET: u64 = 1;
    const EINVALID_THRESHOLD: u64 = 2;
    const EINVALID_LTV: u64 = 3;
    const EINVALID_ENTRY_FEE: u64 = 4;
    const EINVALID_SHARE_FEE: u64 = 5;
    const EINVALID_LIQUIDATION_FEE: u64 = 6;
    const EINVALID_FEE: u64 = 7;

    const PRECISION: u64 = 1000000;
    const DEFAULT_ENTRY_FEE: u64 = 1000000 / 1000 * 5; // 0.5%
    const DEFAULT_SHARE_FEE: u64 = 1000000 / 1000 * 5; // 0.5%
    const DEFAULT_LIQUIDATION_FEE: u64 = 1000000 / 1000 * 5; // 0.5%
    const DEFAULT_LTV: u64 = 1000000 / 100 * 70; // 70%
    const DEFAULT_THRESHOLD: u64 = 1000000 / 100 * 85 ; // 85%
    const SHADOW_LTV: u64 = 1000000 / 100 * 90; // 90%
    const SHADOW_LT: u64 = 1000000 / 100 * 95; // 95%

    //// resources
    /// access control
    struct AssetManagerKey has store, drop {}

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

    public entry fun initialize(owner: &signer) acquires RepositoryEventHandle {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        assert_liquidation_threshold(DEFAULT_LTV, DEFAULT_THRESHOLD);

        let ltv = table::new<string::String,u64>();
        let lt = table::new<string::String,u64>();
        let usdz_name = key<USDZ>();
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
        event::emit_event<UpdateProtocolFeesEvent>(
            &mut borrow_global_mut<RepositoryEventHandle>(owner_addr).update_protocol_fees_event,
                UpdateProtocolFeesEvent {
                    entry_fee: DEFAULT_ENTRY_FEE,
                    share_fee: DEFAULT_SHARE_FEE,
                    liquidation_fee: DEFAULT_LIQUIDATION_FEE,
                    caller: owner_addr,
                }
        )
    }
    //// access control
    public fun publish_asset_manager_key(owner: &signer): AssetManagerKey {
        permission::assert_owner(signer::address_of(owner));
        AssetManagerKey {}
    }

    public fun initialize_for_asset<C>(
        account: &signer,
        _key: &AssetManagerKey
    ) acquires Config, RepositoryAssetEventHandle {
        initialize_for_asset_internal<C>(account);
    }
    fun initialize_for_asset_internal<C>(account: &signer) acquires Config, RepositoryAssetEventHandle {
        let owner_addr = permission::owner_address();
        let config_ref = borrow_global_mut<Config>(owner_addr);
        let key = key<C>();
        assert!(!table::contains<string::String, u64>(&config_ref.ltv, key), error::invalid_argument(EALREADY_ADDED_ASSET));
        table::upsert<string::String,u64>(&mut config_ref.ltv, key, DEFAULT_LTV);
        table::upsert<string::String,u64>(&mut config_ref.lt, key, DEFAULT_THRESHOLD);
        event::emit_event<UpdateConfigEvent>(
            &mut borrow_global_mut<RepositoryAssetEventHandle>(owner_addr).update_config_event,
            UpdateConfigEvent {
                caller: signer::address_of(account),
                key: key,
                ltv: DEFAULT_LTV,
                lt: DEFAULT_THRESHOLD,
            }
        )
    }

    public entry fun update_protocol_fees(
        owner: &signer,
        new_entry_fee: u64,
        new_share_fee: u64,
        new_liquidation_fee: u64
    ) acquires ProtocolFees, RepositoryEventHandle {
        let owner_address = signer::address_of(owner);
        permission::assert_configurator(owner_address);

        assert!(new_entry_fee < PRECISION, error::invalid_argument(EINVALID_ENTRY_FEE));
        assert!(new_share_fee < PRECISION, error::invalid_argument(EINVALID_SHARE_FEE));
        assert!(new_liquidation_fee < PRECISION, error::invalid_argument(EINVALID_LIQUIDATION_FEE));

        update_protocol_fees_internal(owner_address, new_entry_fee, new_share_fee, new_liquidation_fee);
    }
    fun update_protocol_fees_internal(
        owner_addr: address,
        new_entry_fee: u64,
        new_share_fee: u64,
        new_liquidation_fee: u64
    ) acquires ProtocolFees, RepositoryEventHandle {
        let fees = borrow_global_mut<ProtocolFees>(owner_addr);
        fees.entry_fee = new_entry_fee;
        fees.share_fee = new_share_fee;
        fees.liquidation_fee = new_liquidation_fee;
        event::emit_event<UpdateProtocolFeesEvent>(
            &mut borrow_global_mut<RepositoryEventHandle>(owner_addr).update_protocol_fees_event,
            UpdateProtocolFeesEvent {
                caller: owner_addr,
                entry_fee: fees.entry_fee,
                share_fee: fees.share_fee,
                liquidation_fee: fees.liquidation_fee,
            }
        )
    }

    public entry fun update_config<C>(owner: &signer, new_ltv: u64, new_lt: u64) acquires Config, RepositoryAssetEventHandle {
        permission::assert_configurator(signer::address_of(owner));
        let owner_address = signer::address_of(owner);

        let _config = borrow_global_mut<Config>(owner_address);
        let key = key<C>();
        assert_liquidation_threshold(new_ltv, new_lt);

        table::upsert<string::String,u64>(&mut _config.ltv, key, new_ltv);
        table::upsert<string::String,u64>(&mut _config.lt, key, new_lt);
        event::emit_event<UpdateConfigEvent>(
            &mut borrow_global_mut<RepositoryAssetEventHandle>(owner_address).update_config_event,
            UpdateConfigEvent {
                caller: owner_address,
                key,
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
        ltv_of(key<C>())
    }

    public fun ltv_of(name: string::String): u64 acquires Config {
        let config = borrow_global<Config>(permission::owner_address());
        *table::borrow<string::String,u64>(&config.ltv, name)
    } 

    public fun ltv_of_shadow(): u64 acquires Config {
        let config = borrow_global<Config>(permission::owner_address());
        *table::borrow<string::String,u64>(&config.ltv, key<USDZ>())
    }

    public fun lt<C>(): u64 acquires Config {
        lt_of(key<C>())
    }

    public fun lt_of(name: string::String): u64 acquires Config {
        let config = borrow_global<Config>(permission::owner_address());
        *table::borrow<string::String,u64>(&config.lt, name)
    } 

    public fun lt_of_shadow(): u64 acquires Config {
        let config = borrow_global<Config>(permission::owner_address());
        *table::borrow<string::String,u64>(&config.lt, key<USDZ>())
    }

    public fun health_factor_of(key: String, deposited: u128, borrowed: u128): u64 acquires Config {
        if (deposited == 0) {
            0
        } else {
            let precision = precision_u128();
            let scaled_numerator = borrowed * precision * precision;
            let denominator = deposited * (lt_of(key) as u128);
            let u = scaled_numerator / denominator;
            if (precision < u) {
                0
            } else {
                (precision - u as u64)
            }
        }
    }

    /// a, b, c: precision 6
    public fun health_factor_with_quadratic_formula(a: i128::I128, b: i128::I128, c: i128::I128): u128 {
        let a_mul_2 = i128::mul(&a, &i128::from(2));
        let b_pow_2 = i128::mul(&b, &b);
        let minus_ac_mul_4 = i128::neg(&i128::mul(&i128::mul(&a, &c), &i128::from(4)));
        let b_pow_2_sub_4ac = i128::add(&b_pow_2, &minus_ac_mul_4);
        b_pow_2_sub_4ac = i128::div(&b_pow_2_sub_4ac, &i128::from(1000)); // arrange precision
        let square = prb_math::sqrt(i128::as_u128(&b_pow_2_sub_4ac)*1000000000);
        square = square / 1000; // arrange precision
        let x1 = i128::div(
            &i128::mul(
                &i128::add(
                    &i128::neg(&b),
                    &i128::from(square)
                ),
                &i128::from(1000000)
            ),
            &a_mul_2
        );
        let x2 = i128::div(
            &i128::mul(
                &i128::sub(
                    &i128::neg(&b),
                    &i128::from(square)
                ),
                &i128::from(1000000)
            ),
            &a_mul_2
        );
        if (!i128::is_neg(&x1) && i128::as_u128(&x1) < 1000000) {
            1000000 - i128::as_u128(&x1)
        } else {
            1000000 - i128::as_u128(&x2)
        }
    }

    public fun health_factor_weighted_average(keys: vector<String>, deposits: vector<u128>, borrows: vector<u128>): u64 acquires Config {
        assert!(vector::length(&keys) == vector::length(&deposits), 0);
        assert!(vector::length(&keys) == vector::length(&borrows), 0);

        let borrowed_sum = 0;
        let collateral_sum = 0;
        let i = vector::length(&keys);
        while (i > 0) {
            let key = *vector::borrow(&keys, i-1);
            let deposited = *vector::borrow(&deposits, i-1);
            let borrowed = *vector::borrow(&borrows, i-1);
            borrowed_sum = borrowed_sum + borrowed;
            collateral_sum = collateral_sum + deposited * (lt_of(key) as u128);
            i = i - 1;
        };

        let precision = precision_u128();
        if (collateral_sum == 0) {
            0
        } else {
            let u = borrowed_sum * precision / (collateral_sum / precision);
            if (precision < u) {
                0
            } else {
                (precision - u as u64)
            }
        }
    }
    public fun health_factor_weighted_average_by_map(keys: vector<String>, deposits: SimpleMap<String, u128>, borrows: SimpleMap<String, u128>): u64 acquires Config {
        let deposits_vec = vector::empty<u128>();
        let borrows_vec = vector::empty<u128>();
        let i = 0;
        while (i < vector::length(&keys)) {
            let key = vector::borrow(&keys, i);
            vector::push_back(&mut deposits_vec, *simple_map::borrow(&deposits, key));
            vector::push_back(&mut borrows_vec, *simple_map::borrow(&borrows, key));
            i = i + 1;
        };
        health_factor_weighted_average(keys, deposits_vec, borrows_vec)
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
    public fun liquidation_fee(): u64 acquires ProtocolFees {
        borrow_global<ProtocolFees>(permission::owner_address()).liquidation_fee
    }
    public fun calculate_liquidation_fee(value: u64): u64 acquires ProtocolFees {
        calculate_fee_with_round_up(value, liquidation_fee())
    }
    //// for round up
    fun calculate_fee_with_round_up(value: u64, fee: u64): u64 {
        assert!(fee <= precision(), error::invalid_argument(EINVALID_FEE));
        let value_mul_by_fee = (value as u128) * (fee as u128); // NOTE: as not to overflow
        let result = value_mul_by_fee / precision_u128();
        if (value_mul_by_fee % precision_u128() != 0) (result + 1 as u64) else (result as u64)
    }

    public fun precision(): u64 {
        PRECISION
    }
    public fun precision_u128(): u128 {
        (PRECISION as u128)
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_common::test_coin::{Self,WETH};
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
    public fun update_protocol_fees_unsafe(
        new_entry_fee: u64,
        new_share_fee: u64,
        new_liquidation_fee: u64
    ) acquires ProtocolFees, RepositoryEventHandle {
        update_protocol_fees_internal(permission::owner_address(), new_entry_fee, new_share_fee, new_liquidation_fee);
    }
    #[test(owner = @leizd_aptos_logic)]
    fun test_initialize(owner: signer) acquires ProtocolFees, RepositoryEventHandle {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        permission::initialize(&owner);
        initialize(&owner);

        let protocol_fees = borrow_global<ProtocolFees>(owner_addr);
        assert!(protocol_fees.entry_fee == DEFAULT_ENTRY_FEE, 0);
        assert!(protocol_fees.share_fee == DEFAULT_SHARE_FEE, 0);
        assert!(protocol_fees.liquidation_fee == DEFAULT_LIQUIDATION_FEE, 0);
        let event_handle = borrow_global<RepositoryEventHandle>(owner_addr);
        assert!(event::counter(&event_handle.update_protocol_fees_event) == 1, 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_initialize_without_owner(account: signer) acquires RepositoryEventHandle {
        initialize(&account);
    }
    #[test(owner=@leizd_aptos_logic,account1=@0x111)]
    fun test_update_protocol_fees(owner: signer, account1: signer) acquires Config, ProtocolFees, RepositoryEventHandle, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        permission::initialize(&owner);

        test_coin::init_weth(&owner);
        initialize(&owner);
        initialize_for_asset_internal<WETH>(&owner);
        managed_coin::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);

        let new_entry_fee = PRECISION / 1000 * 8; // 0.8%
        let new_share_fee = PRECISION / 1000 * 7; // 0.7%,
        let new_liquidation_fee = PRECISION / 1000 * 6; // 0.6%,
        update_protocol_fees(&owner, new_entry_fee, new_share_fee, new_liquidation_fee);
        let fees = borrow_global<ProtocolFees>(permission::owner_address());
        assert!(fees.entry_fee == PRECISION / 1000 * 8, 0);
        assert!(fees.share_fee == PRECISION / 1000 * 7, 0);
        assert!(fees.liquidation_fee == PRECISION / 1000 * 6, 0);
        let event_handle = borrow_global<RepositoryEventHandle>(owner_addr);
        assert!(event::counter(&event_handle.update_protocol_fees_event) == 2, 0);
    }
    #[test(owner=@leizd_aptos_logic, account = @0x111)]
    #[expected_failure(abort_code = 65540)]
    fun test_update_protocol_fees_without_configurator(owner: &signer, account: &signer) acquires ProtocolFees, RepositoryEventHandle {
        permission::initialize(owner);
        let new_entry_fee = PRECISION / 1000 * 8;
        let new_share_fee = PRECISION;
        let new_liquidation_fee = PRECISION / 1000 * 6;
        update_protocol_fees(account, new_entry_fee, new_share_fee, new_liquidation_fee);
    }
    #[test(owner=@leizd_aptos_logic)]
    #[expected_failure(abort_code = 65541)]
    fun test_update_protocol_fees_when_share_fee_is_greater_than_100(owner: signer) acquires Config, ProtocolFees, RepositoryEventHandle, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        permission::initialize(&owner);
        initialize(&owner);
        initialize_for_asset_internal<WETH>(&owner);

        let new_entry_fee = PRECISION / 1000 * 8; // 0.8%
        let new_share_fee = PRECISION;
        let new_liquidation_fee = PRECISION / 1000 * 6; // 0.6%,
        update_protocol_fees(&owner, new_entry_fee, new_share_fee, new_liquidation_fee);
    }
    #[test(owner=@leizd_aptos_logic)]
    #[expected_failure(abort_code = 65542)]
    fun test_update_protocol_fees_when_liquidation_fee_is_greater_than_100(owner: signer) acquires Config, ProtocolFees, RepositoryEventHandle, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        permission::initialize(&owner);
        initialize(&owner);
        initialize_for_asset_internal<WETH>(&owner);

        let new_entry_fee = PRECISION / 1000 * 8; // 0.8%
        let new_share_fee = PRECISION / 1000 * 7; // 0.7%,
        let new_liquidation_fee = PRECISION;
        update_protocol_fees(&owner, new_entry_fee, new_share_fee, new_liquidation_fee);
    }
    #[test(owner=@leizd_aptos_logic)]
    #[expected_failure(abort_code = 65540)]
    fun test_update_protocol_fees_when_entry_fee_is_greater_than_100(owner: signer) acquires Config, ProtocolFees, RepositoryEventHandle, RepositoryAssetEventHandle {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        permission::initialize(&owner);
        initialize(&owner);
        initialize_for_asset_internal<WETH>(&owner);

        let new_entry_fee = PRECISION;
        let new_share_fee = PRECISION / 1000 * 7; // 0.7%,
        let new_liquidation_fee = PRECISION / 1000 * 6; // 0.6%,
        update_protocol_fees(&owner, new_entry_fee, new_share_fee, new_liquidation_fee);
    }
    #[test_only]
    struct TestAsset {}
    #[test(owner = @leizd_aptos_logic)]
    fun test_initialize_for_asset(owner: &signer) acquires Config, RepositoryAssetEventHandle, RepositoryEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        permission::initialize(owner);
        initialize(owner);
        initialize_for_asset_internal<TestAsset>(owner);

        let name = key<TestAsset>();
        let config = borrow_global<Config>(owner_addr);
        let new_ltv = table::borrow<string::String,u64>(&config.ltv, name);
        let new_lt = table::borrow<string::String,u64>(&config.lt, name);

        assert!(*new_ltv == DEFAULT_LTV, 0);
        assert!(*new_lt == DEFAULT_THRESHOLD, 0);
    }

    #[test(owner = @leizd_aptos_logic)]
    #[expected_failure(abort_code = 65537)]
    fun test_initialize_for_asset_twice(owner: &signer) acquires Config, RepositoryAssetEventHandle, RepositoryEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        permission::initialize(owner);
        initialize(owner);
        initialize_for_asset_internal<TestAsset>(owner);
        initialize_for_asset_internal<TestAsset>(owner);
    }
    #[test(owner=@leizd_aptos_logic)]
    fun test_update_config(owner: &signer) acquires Config, RepositoryAssetEventHandle, RepositoryEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        permission::initialize(owner);
        initialize(owner);
        initialize_for_asset_internal<TestAsset>(owner);
        let name = key<TestAsset>();
        assert!(ltv<TestAsset>() == PRECISION / 100 * 70, 0);
        assert!(lt<TestAsset>() == PRECISION / 100 * 85, 0);
        assert!(lt_of(name) == PRECISION / 100 * 85, 0);

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
    #[test(owner=@leizd_aptos_logic, account = @0x111)]
    #[expected_failure(abort_code = 65540)]
    fun test_update_config_without_configurator(owner: &signer, account: &signer) acquires Config, RepositoryAssetEventHandle {
        permission::initialize(owner);
        update_config<TestAsset>(account, PRECISION / 100 * 70, PRECISION / 100 * 90);
    }
    #[test(owner=@leizd_aptos_logic)]
    fun test_update_config_with_usdz(owner: &signer) acquires Config, RepositoryAssetEventHandle, RepositoryEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        permission::initialize(owner);
        initialize(owner);

        update_config<USDZ>(owner, PRECISION / 100 * 20, PRECISION / 100 * 40);
        let config = borrow_global<Config>(permission::owner_address());
        let name = key<USDZ>();
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
    #[test(owner=@leizd_aptos_logic)]
    #[expected_failure(abort_code = 65538)]
    fun test_update_config_when_lt_is_greater_than_100(owner: &signer) acquires Config, RepositoryAssetEventHandle, RepositoryEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        permission::initialize(owner);
        initialize(owner);
        initialize_for_asset_internal<TestAsset>(owner);
        update_config<TestAsset>(owner, 1, PRECISION + 1);
    }
    #[test(owner=@leizd_aptos_logic)]
    #[expected_failure(abort_code = 65539)]
    fun test_update_config_when_ltv_is_0(owner: &signer) acquires Config, RepositoryAssetEventHandle, RepositoryEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        permission::initialize(owner);
        initialize(owner);
        initialize_for_asset_internal<TestAsset>(owner);
        update_config<TestAsset>(owner, 0, PRECISION);
    }
    #[test(owner=@leizd_aptos_logic)]
    fun test_update_config_when_ltv_is_equal_to_lt(owner: &signer) acquires Config, RepositoryAssetEventHandle, RepositoryEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        permission::initialize(owner);
        initialize(owner);
        initialize_for_asset_internal<TestAsset>(owner);
        update_config<TestAsset>(owner, PRECISION / 100 * 50, PRECISION / 100 * 50);
        assert!(ltv<TestAsset>() == PRECISION / 100 * 50, 0);
        assert!(lt<TestAsset>() == PRECISION / 100 * 50, 0);
    }
    #[test(owner = @leizd_aptos_logic)]
    fun test_calculate_entry_fee(owner: &signer) acquires ProtocolFees, RepositoryEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        permission::initialize(owner);
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
    #[test(owner = @leizd_aptos_logic)]
    fun test_calculate_share_fee(owner: &signer) acquires ProtocolFees, RepositoryEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        permission::initialize(owner);
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
    #[test(owner = @leizd_aptos_logic)]
    fun test_calculate_liquidation_fee(owner: &signer) acquires ProtocolFees, RepositoryEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        permission::initialize(owner);
        initialize(owner);

        // Prerequisite
        assert!(liquidation_fee() == default_liquidation_fee(), 0);

        // Execute
        assert!(calculate_liquidation_fee(100000) == 500, 0);
        assert!(calculate_liquidation_fee(100001) == 501, 0);
        assert!(calculate_liquidation_fee(99999) == 500, 0);
        assert!(calculate_liquidation_fee(200) == 1, 0);
        assert!(calculate_liquidation_fee(199) == 1, 0);
        assert!(calculate_liquidation_fee(1) == 1, 0);
        assert!(calculate_liquidation_fee(0) == 0, 0);
    }
    #[test(owner = @leizd_aptos_logic)]
    fun test_calculate_fee_with_round_up__check_overflow(owner: &signer) acquires ProtocolFees, RepositoryEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);

        let u64_max: u64 = 18446744073709551615;
        calculate_fee_with_round_up(u64_max, entry_fee());
        calculate_fee_with_round_up(u64_max, precision());
    }
    #[test]
    #[expected_failure(abort_code = 65543)]
    fun test_calculate_fee_with_round_up_when_fee_is_greater_than_precision() {
        let u64_max: u64 = 18446744073709551615;
        calculate_fee_with_round_up(u64_max, precision() + 1);
    }
}
