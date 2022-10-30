module leizd_aptos_external::pyth_adaptor {
    use std::error;
    use std::signer;
    use std::string::String;
    use aptos_std::event;
    use aptos_std::simple_map;
    use aptos_framework::account;
    use leizd_aptos_common::permission;
    use leizd_aptos_common::coin_key::{key};
    use pyth::pyth;
    use pyth::price;
    use pyth::i64;
    use pyth::price_identifier;

    const ENOT_INITIALIZED: u64 = 1;
    const EALREADY_INITIALIZED: u64 = 2;
    const ENOT_REGISTERED: u64 = 3;
    const EALREADY_REGISTERED: u64 = 4;

    struct Storage has key {
        price_feed_ids: simple_map::SimpleMap<String, vector<u8>>
    }

    struct UpdatePriceFeedEvent has store, drop {
        key: String,
        price_feed_id: vector<u8>,
    }
    struct PythAdaptorEventHandle has key {
        update_price_feed_event: event::EventHandle<UpdatePriceFeedEvent>,
    }

    ////////////////////////////////////////////////////
    /// Manage module
    ////////////////////////////////////////////////////
    public entry fun initialize(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        assert!(!exists<Storage>(owner_addr), error::invalid_argument(EALREADY_INITIALIZED));
        move_to(owner, Storage { price_feed_ids: simple_map::create<String, vector<u8>>() });
        move_to(owner, PythAdaptorEventHandle {
            update_price_feed_event: account::new_event_handle<UpdatePriceFeedEvent>(owner),
        });
    }

    public entry fun add_price_feed<C>(owner: &signer, price_feed_id: vector<u8>) acquires Storage, PythAdaptorEventHandle {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        let key = key<C>();
        assert!(exists<Storage>(owner_addr), error::invalid_argument(ENOT_INITIALIZED));
        assert!(!is_registered(key), error::invalid_argument(EALREADY_REGISTERED));
        let ids = &mut borrow_global_mut<Storage>(owner_addr).price_feed_ids;
        simple_map::add(ids, key, price_feed_id);
        event::emit_event(
            &mut borrow_global_mut<PythAdaptorEventHandle>(owner_addr).update_price_feed_event,
            UpdatePriceFeedEvent { key, price_feed_id },
        );
    }

    fun is_registered(key: String): bool acquires Storage {
        let storage_ref = borrow_global<Storage>(permission::owner_address());
        is_registered_internal(key, storage_ref)
    }
    fun is_registered_internal(key: String, storage: &Storage): bool {
        simple_map::contains_key(&storage.price_feed_ids, &key)
    }

    ////////////////////////////////////////////////////
    /// Feed
    ////////////////////////////////////////////////////
    fun price_from_feeder(price_feed_id: vector<u8>): (u64, u64) {
        let identifier = price_identifier::from_byte_vec(price_feed_id);
        let price_obj = pyth::get_price(identifier);
        let price_mag = i64::get_magnitude_if_positive(&price::get_price(&price_obj));
        let expo_mag = i64::get_magnitude_if_positive(&price::get_expo(&price_obj));
        (price_mag, expo_mag) // TODO: use pyth::i64::I64.negative
    }
    fun price_internal(key: String): (u64, u64) acquires Storage {
        let owner_addr = permission::owner_address();
        assert!(exists<Storage>(owner_addr), error::invalid_argument(ENOT_INITIALIZED));
        assert!(is_registered(key), error::invalid_argument(ENOT_REGISTERED));
        let price_feed_ids = &borrow_global<Storage>(owner_addr).price_feed_ids;
        let price_feed_id = simple_map::borrow(price_feed_ids, &key);
        price_from_feeder(*price_feed_id)
    }
    public fun price<C>(): (u64, u64) acquires Storage {
        let (value, dec) = price_internal(key<C>());
        (value, dec)
    }
    public fun price_of(name: &String): (u64, u64) acquires Storage {
        let (value, dec) = price_internal(*name);
        (value, dec)
    }

    #[test_only]
    use leizd_aptos_common::test_coin::{WETH};
    #[test(owner = @leizd_aptos_external)]
    fun test_initialize(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        assert!(exists<Storage>(owner_addr), 0);
        assert!(exists<PythAdaptorEventHandle>(owner_addr), 0);
    }
    #[test(account = @0x111)]
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
    fun test_add_price_feed(owner: &signer) acquires Storage, PythAdaptorEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        add_price_feed<WETH>(owner, b"0x123");
        let id = simple_map::borrow(&borrow_global<Storage>(owner_addr).price_feed_ids, &key<WETH>());
        assert!(id == &(b"0x123"), 0);
        assert!(event::counter(&borrow_global<PythAdaptorEventHandle>(owner_addr).update_price_feed_event) == 1, 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_add_price_feed_with_not_owner(account: &signer) acquires Storage, PythAdaptorEventHandle {
        add_price_feed<WETH>(account, b"0x123");
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure(abort_code = 65537)]
    fun test_add_price_feed_before_initialize(owner: &signer) acquires Storage, PythAdaptorEventHandle {
        add_price_feed<WETH>(owner, b"0x123");
    }
    #[test(owner = @leizd_aptos_external)]
    #[expected_failure(abort_code = 65540)]
    fun test_add_price_feed_twice(owner: &signer) acquires Storage, PythAdaptorEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        add_price_feed<WETH>(owner, b"0x123");
        add_price_feed<WETH>(owner, b"0x123");
    }
}
