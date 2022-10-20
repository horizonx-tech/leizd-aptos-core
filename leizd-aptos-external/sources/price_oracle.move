module leizd_aptos_external::price_oracle {
    use std::error;
    use std::signer;
    use std::string::String;
    use aptos_std::event;
    use aptos_std::simple_map;
    use aptos_framework::account;
    use leizd_aptos_lib::math128;
    use leizd_aptos_common::permission;
    use leizd_aptos_common::coin_key::{key};

    const ENOT_INITIALIZED: u64 = 1;
    const EALREADY_INITIALIZED: u64 = 2;
    const ENOT_REGISTERED: u64 = 3;
    const EALREADY_REGISTERED: u64 = 4;
    const EINACTIVE: u64 = 5;

    const INACTIVE: u8 = 0;
    const FIXED_PRICE: u8 = 1;
    const SWITCHBOARD: u8 = 2;

    struct Storage has key {
        oracles: simple_map::SimpleMap<String, OracleContainer>
    }
    struct OracleContainer has store {
        mode: u8,
        is_enabled_fixed_price: bool,
        fixed_price: PriceDecimal
    }
    struct PriceDecimal has copy, drop, store { value: u128, dec: u8, neg: bool }

    struct UpdateOracleEvent has store, drop {
        key: String,
        mode: u8,
    }
    struct OracleEventHandle has key {
        update_oracle_event: event::EventHandle<UpdateOracleEvent>,
    }

    ////////////////////////////////////////////////////
    /// Manage module
    ////////////////////////////////////////////////////
    public entry fun initialize(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(signer::address_of(owner));
        assert!(!exists<Storage>(owner_addr), error::invalid_argument(EALREADY_INITIALIZED));
        move_to(owner, Storage {
            oracles: simple_map::create<String, OracleContainer>()
        });
        move_to(owner, OracleEventHandle {
            update_oracle_event: account::new_event_handle<UpdateOracleEvent>(owner),
        });
    }

    public entry fun register_oracle_without_fixed_price<C>(account: &signer) acquires Storage, OracleEventHandle {
        register_oracle_internal(account, key<C>(), OracleContainer {
            mode: INACTIVE,
            is_enabled_fixed_price: false,
            fixed_price: PriceDecimal { value: 0, dec: 0, neg: false }
        });
    }
    public entry fun register_oracle_with_fixed_price<C>(account: &signer, value: u128, dec: u8, neg: bool) acquires Storage, OracleEventHandle {
        register_oracle_internal(account, key<C>(), OracleContainer {
            mode: INACTIVE,
            is_enabled_fixed_price: true,
            fixed_price: PriceDecimal { value, dec, neg }
        });
    }
    fun register_oracle_internal(owner: &signer, key: String, oracle: OracleContainer) acquires Storage, OracleEventHandle {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        assert!(exists<Storage>(owner_addr), error::invalid_argument(ENOT_INITIALIZED));
        assert!(!is_registered(key), error::invalid_argument(EALREADY_REGISTERED));
        let storage = borrow_global_mut<Storage>(owner_addr);
        let new_mode = oracle.mode;
        simple_map::add<String, OracleContainer>(&mut storage.oracles, key, oracle);
        event::emit_event<UpdateOracleEvent>(
            &mut borrow_global_mut<OracleEventHandle>(owner_addr).update_oracle_event,
            UpdateOracleEvent {
                key,
                mode: new_mode
            },
        );
    }
    fun is_registered(key: String): bool acquires Storage {
        let storage_ref = borrow_global<Storage>(permission::owner_address());
        is_registered_internal(key, storage_ref)
    }
    fun is_registered_internal(key: String, storage: &Storage): bool {
        simple_map::contains_key(&storage.oracles, &key)
    }

    public entry fun change_mode<C>(owner: &signer, new_mode: u8) acquires Storage, OracleEventHandle {
        let owner_addr = signer::address_of(owner);
        let key = key<C>();
        permission::assert_owner(owner_addr);
        assert!(exists<Storage>(owner_addr), error::invalid_argument(ENOT_INITIALIZED));
        assert!(is_registered(key), error::invalid_argument(ENOT_REGISTERED));
        let oracle_ref = simple_map::borrow_mut(&mut borrow_global_mut<Storage>(owner_addr).oracles, &key);
        oracle_ref.mode = new_mode;
        event::emit_event<UpdateOracleEvent>(
            &mut borrow_global_mut<OracleEventHandle>(owner_addr).update_oracle_event,
            UpdateOracleEvent {
                key,
                mode: new_mode
            },
        );
    }

    public entry fun update_fixed_price<C>(owner: &signer, value: u128, dec: u8, neg: bool) acquires Storage {
        let owner_addr = signer::address_of(owner);
        let key = key<C>();
        permission::assert_owner(owner_addr);
        assert!(exists<Storage>(owner_addr), error::invalid_argument(ENOT_INITIALIZED));
        assert!(is_registered(key), error::invalid_argument(ENOT_REGISTERED));
        let oracle_ref = simple_map::borrow_mut(&mut borrow_global_mut<Storage>(owner_addr).oracles, &key);
        oracle_ref.fixed_price = PriceDecimal { value, dec, neg };
    }

    ////////////////////////////////////////////////////
    /// View function
    ////////////////////////////////////////////////////
    public fun fixed_price_mode(): u8 {
        FIXED_PRICE
    }
    public fun mode<C>(): u8 acquires Storage {
        mode_internal(key<C>())
    }
    fun mode_internal(key: String): u8 acquires Storage {
        let oracle_ref = simple_map::borrow(&borrow_global<Storage>(permission::owner_address()).oracles, &key);
        oracle_ref.mode
    }

    ////////////////////////////////////////////////////
    /// Feed
    ////////////////////////////////////////////////////
    public fun price<C>(): (u128, u8) acquires Storage {
        price_internal(&key<C>())
    }
    public fun price_of(key: &String): (u128, u8) acquires Storage {
        price_internal(key)
    }
    fun price_internal(key: &String): (u128, u8) acquires Storage {
        assert!(is_registered(*key), error::invalid_argument(ENOT_REGISTERED));
        let oracle = simple_map::borrow(&borrow_global<Storage>(permission::owner_address()).oracles, key);
        if (oracle.mode == FIXED_PRICE) return (oracle.fixed_price.value, oracle.fixed_price.dec);
        // if (oracle.mode == SWITCHBOARD) return leizd_aptos_external::switchboard_adaptor::price_of(key);
        abort error::invalid_argument(EINACTIVE)
    }

    public fun volume(name: &String, amount: u128): u128 acquires Storage {
        let (value, dec) = price_of(name);
        let numerator = amount * value; // TODO: check overflow
        numerator / math128::pow(10, (dec as u128))
    }

    public fun to_amount(name: &String, volume: u128): u128 acquires Storage {
        let (value, dec) = price_of(name);
        let numerator = volume * math128::pow(10, (dec as u128)); // TODO: check overflow
        numerator / value
    }

    #[test_only]
    use leizd_aptos_common::test_coin::{WETH};
    #[test(owner = @leizd_aptos_external)]
    fun test_initialize(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        assert!(exists<Storage>(owner_addr), 0);
        assert!(exists<OracleEventHandle>(owner_addr), 0);
    }
    #[test(account = @0x1)]
    #[expected_failure(abort_code = 65537)]
    fun test_initialize_with_not_owner(account: &signer) {
        initialize(account);
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure(abort_code = 65538)]
    fun test_initialize_twice(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        initialize(owner);
    }
    #[test(owner = @leizd_aptos_external)]
    fun test_register_oracle_without_fixed_price(owner: &signer) acquires Storage, OracleEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        register_oracle_without_fixed_price<WETH>(owner);
        let oracle = simple_map::borrow(&borrow_global<Storage>(signer::address_of(owner)).oracles, &key<WETH>());
        assert!(oracle.mode == 0, 0);
        assert!(oracle.is_enabled_fixed_price == false, 0);
        assert!(oracle.fixed_price == PriceDecimal { value: 0, dec: 0, neg: false }, 0);
        assert!(event::counter<UpdateOracleEvent>(&borrow_global<OracleEventHandle>(signer::address_of(owner)).update_oracle_event) == 1, 0);
    }
    #[test(account = @0x1)]
    #[expected_failure(abort_code = 65537)]
    fun test_register_oracle_without_fixed_price_with_not_owner(account: &signer) acquires Storage, OracleEventHandle {
        register_oracle_without_fixed_price<WETH>(account);
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure(abort_code = 65537)]
    fun test_register_oracle_without_fixed_price_before_initialize(owner: &signer) acquires Storage, OracleEventHandle {
        register_oracle_without_fixed_price<WETH>(owner);
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure(abort_code = 65540)]
    fun test_register_oracle_without_fixed_price_twice(owner: &signer) acquires Storage, OracleEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        register_oracle_without_fixed_price<WETH>(owner);
        register_oracle_without_fixed_price<WETH>(owner);
    }
    #[test(owner = @leizd_aptos_external)]
    fun test_register_oracle_with_fixed_price(owner: &signer) acquires Storage, OracleEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        register_oracle_with_fixed_price<WETH>(owner, 100, 9, false);
        let oracle = simple_map::borrow(&borrow_global<Storage>(owner_addr).oracles, &key<WETH>());
        assert!(oracle.mode == 0, 0);
        assert!(oracle.is_enabled_fixed_price == true, 0);
        assert!(oracle.fixed_price == PriceDecimal { value: 100, dec: 9, neg: false }, 0);
        assert!(event::counter<UpdateOracleEvent>(&borrow_global<OracleEventHandle>(owner_addr).update_oracle_event) == 1, 0);
    }
    #[test(account = @0x1)]
    #[expected_failure(abort_code = 65537)]
    fun test_register_oracle_with_fixed_price_with_not_owner(account: &signer) acquires Storage, OracleEventHandle {
        register_oracle_with_fixed_price<WETH>(account, 100, 9, false);
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure(abort_code = 65537)]
    fun test_register_oracle_with_fixed_price_before_initialize(owner: &signer) acquires Storage, OracleEventHandle {
        register_oracle_with_fixed_price<WETH>(owner, 100, 9, false);
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure(abort_code = 65540)]
    fun test_register_oracle_with_fixed_price_twice(owner: &signer) acquires Storage, OracleEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        register_oracle_with_fixed_price<WETH>(owner, 100, 9, false);
        register_oracle_with_fixed_price<WETH>(owner, 100, 9, false);
    }

    #[test(owner = @leizd_aptos_external)]
    fun test_change_mode(owner: &signer) acquires Storage, OracleEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        register_oracle_without_fixed_price<WETH>(owner);
        assert!(event::counter<UpdateOracleEvent>(&borrow_global<OracleEventHandle>(owner_addr).update_oracle_event) == 1, 0);
        change_mode<WETH>(owner, 9);

        let oracle = simple_map::borrow(&borrow_global<Storage>(owner_addr).oracles, &key<WETH>());
        assert!(oracle.mode == 9, 0);
        assert!(event::counter<UpdateOracleEvent>(&borrow_global<OracleEventHandle>(owner_addr).update_oracle_event) == 2, 0);
    }
    #[test(account = @0x1)]
    #[expected_failure(abort_code = 65537)]
    fun test_change_mode_with_not_owner(account: &signer) acquires Storage, OracleEventHandle {
        change_mode<WETH>(account, 9);
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure(abort_code = 65537)]
    fun test_change_mode_before_initialize(owner: &signer) acquires Storage, OracleEventHandle {
        change_mode<WETH>(owner, 9);
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure(abort_code = 65539)]
    fun test_change_mode_before_register_oracle(owner: &signer) acquires Storage, OracleEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        change_mode<WETH>(owner, 9);
    }
    #[test(owner = @leizd_aptos_external)]
    fun test_update_fixed_price(owner: &signer) acquires Storage, OracleEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        register_oracle_without_fixed_price<WETH>(owner);
        update_fixed_price<WETH>(owner, 1, 1, false);

        let oracle = simple_map::borrow(&borrow_global<Storage>(owner_addr).oracles, &key<WETH>());
        assert!(oracle.fixed_price == PriceDecimal { value: 1, dec: 1, neg: false }, 0);
    }
    #[test(account = @0x1)]
    #[expected_failure(abort_code = 65537)]
    fun test_update_fixed_price_with_not_owner(account: &signer) acquires Storage {
        update_fixed_price<WETH>(account, 1, 1, false);
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure(abort_code = 65537)]
    fun test_update_fixed_price_before_initialize(owner: &signer) acquires Storage {
        update_fixed_price<WETH>(owner, 100, 9, false);
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure(abort_code = 65539)]
    fun test_update_fixed_price_before_register_oracle(owner: &signer) acquires Storage {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        update_fixed_price<WETH>(owner, 100, 9, false);
    }

    #[test(owner = @leizd_aptos_external)]
    fun test_price_when_using_fixed_value(owner: &signer) acquires Storage, OracleEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        register_oracle_with_fixed_price<WETH>(owner, 100, 9, false);
        change_mode<WETH>(owner, fixed_price_mode());
        assert!(mode<WETH>() == FIXED_PRICE, 0);

        let (val, dec) = price<WETH>();
        assert!(val == 100, 0);
        assert!(dec == 9, 0);
        let (val, dec) = price_of(&key<WETH>());
        assert!(val == 100, 0);
        assert!(dec == 9, 0);

        update_fixed_price<WETH>(owner, 50000, 1, false);

        let (val, dec) = price<WETH>();
        assert!(val == 50000, 0);
        assert!(dec == 1, 0);
        let (val, dec) = price_of(&key<WETH>());
        assert!(val == 50000, 0);
        assert!(dec == 1, 0);
    }

    #[test_only]
    struct DummyCoin {}
    #[test(owner = @leizd_aptos_external)]
    fun test_volume(owner: &signer) acquires Storage, OracleEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        register_oracle_with_fixed_price<DummyCoin>(owner, math128::pow(10, 8) * 5 / 100, 8, false); // 0.05
        change_mode<DummyCoin>(owner, fixed_price_mode());
        assert!(mode<DummyCoin>() == FIXED_PRICE, 0);

        let (val, dec) = price<DummyCoin>();
        assert!(val == math128::pow(10, 8) * 5 / 100, 0);
        assert!(dec == 8, 0);

        assert!(volume(&key<DummyCoin>(), 100) == 5, 0);
        assert!(volume(&key<DummyCoin>(), 2000) == 100, 0);
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure] // TODO: not fail
    fun test_volume__check_overflow(owner: &signer) acquires Storage, OracleEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        register_oracle_with_fixed_price<DummyCoin>(owner, math128::pow(10, 8) * 50000, 8, false); // 50000
        change_mode<DummyCoin>(owner, fixed_price_mode());
        assert!(mode<DummyCoin>() == FIXED_PRICE, 0);

        let (val, dec) = price<DummyCoin>();
        assert!(val == math128::pow(10, 8) * 50000, 0);
        assert!(dec == 8, 0);

        let u128_max: u128 = 340282366920938463463374607431768211455;
        volume(&key<DummyCoin>(), u128_max);
    }
    #[test(owner = @leizd_aptos_external)]
    fun test_to_amount(owner: &signer) acquires Storage, OracleEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        register_oracle_with_fixed_price<DummyCoin>(owner, math128::pow(10, 8) * 5 / 100, 8, false); // 0.05
        change_mode<DummyCoin>(owner, fixed_price_mode());
        assert!(mode<DummyCoin>() == FIXED_PRICE, 0);

        let (val, dec) = price<DummyCoin>();
        assert!(val == math128::pow(10, 8) * 5 / 100, 0);
        assert!(dec == 8, 0);

        assert!(to_amount(&key<DummyCoin>(), 5) == 100, 0);
        assert!(to_amount(&key<DummyCoin>(), 100) == 2000, 0);
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure] // TODO: not fail
    fun test_to_amount__check_overflow(owner: &signer) acquires Storage, OracleEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        register_oracle_with_fixed_price<DummyCoin>(owner, math128::pow(10, 8) * 5 / 10000, 8, false); // 0.0005
        change_mode<DummyCoin>(owner, fixed_price_mode());
        assert!(mode<DummyCoin>() == FIXED_PRICE, 0);

        let (val, dec) = price<DummyCoin>();
        assert!(val == math128::pow(10, 8) * 5 / 10000, 0);
        assert!(dec == 8, 0);

        let u128_max: u128 = 340282366920938463463374607431768211455;
        to_amount(&key<DummyCoin>(), u128_max);
    }
}
