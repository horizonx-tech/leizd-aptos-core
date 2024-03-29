module leizd::pool_manager {

    use std::error;
    use std::signer;
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::simple_map;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::type_info::{Self, TypeInfo};
    use leizd_aptos_common::coin_key;
    use leizd_aptos_common::permission;
    use leizd::asset_pool;
    use leizd::shadow_pool;

    const ENOT_INITIALIZED: u64 = 1;
    const EALREADY_ADDED_COIN: u64 = 2;
    const ENOT_INITIALIZED_COIN: u64 = 3;

    struct PoolInfo has store {
        type_info: TypeInfo,
        holder: address
    }

    struct PoolList has key {
        infos: simple_map::SimpleMap<String, PoolInfo>, // key: type_name
    }

    struct PoolManagerEventHandle has key, store {
        add_pool_event: event::EventHandle<AddPoolEvent>
    }

    struct AddPoolEvent has store, drop {
        caller: address,
        info: TypeInfo,
        coin_info: CoinInfo,
    }

    struct CoinInfo has store, drop {
        name: String,
        symbol: String,
        decimals: u8,
    }


    public entry fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        assert!(!is_initialized(), error::invalid_argument(ENOT_INITIALIZED));
        move_to(owner, PoolList { infos: simple_map::create<String, PoolInfo>() });
        move_to(owner, PoolManagerEventHandle {
        add_pool_event: account::new_event_handle<AddPoolEvent>(owner)
        });
    }

    fun is_initialized(): bool {
        exists<PoolList>(permission::owner_address())
    }

    public entry fun add_pool<C>(holder: &signer) acquires PoolList, PoolManagerEventHandle {
        assert!(!is_exist<C>(), error::invalid_argument(EALREADY_ADDED_COIN));
        assert!(coin::is_coin_initialized<C>(), error::invalid_argument(ENOT_INITIALIZED_COIN));
        let pool_list = borrow_global_mut<PoolList>(permission::owner_address());
        asset_pool::init_pool<C>(holder);
        shadow_pool::init_pool<C>();
        
        simple_map::add<String, PoolInfo>(&mut pool_list.infos, coin_key::key<C>(), PoolInfo {
        type_info: type_info::type_of<C>(),
        holder: signer::address_of(holder)
        });
        event::emit_event<AddPoolEvent>(
        &mut borrow_global_mut<PoolManagerEventHandle>(permission::owner_address()).add_pool_event,
            AddPoolEvent {
            caller: signer::address_of(holder),
            info: type_info::type_of<C>(),
            coin_info: CoinInfo {
                name: coin::name<C>(),
                symbol: coin::symbol<C>(),
                decimals: coin::decimals<C>(),
            }
            },
        );
    }

    fun is_exist<C>(): bool acquires PoolList {
        is_exist_internal(coin_key::key<C>())
    }

    fun is_exist_internal(key: String): bool acquires PoolList {
        let pool_list = borrow_global<PoolList>(permission::owner_address());
        simple_map::contains_key<String, PoolInfo>(&pool_list.infos, &key)
    }

    #[test_only]
    use leizd_aptos_common::test_coin::{Self, WETH, USDC, USDT, UNI};
    #[test_only]
    use leizd_aptos_common::pool_status;
    #[test_only]
    use leizd_aptos_logic::risk_factor;
    #[test_only]
    use leizd_aptos_treasury::treasury;
    #[test_only]
    use leizd_aptos_central_liquidity_pool::central_liquidity_pool;
    #[test_only]
    use leizd::interest_rate;
    #[test_only]
    use leizd_aptos_trove::usdz;
    #[test_only]
    fun set_up(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        usdz::initialize_for_test(owner);
        central_liquidity_pool::initialize(owner);
        test_coin::init_weth(owner);
        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        risk_factor::initialize(owner);
        treasury::initialize(owner);
        interest_rate::initialize(owner);
        pool_status::initialize(owner);
        asset_pool::initialize(owner);
        shadow_pool::initialize(owner);
    }
    
    #[test_only]
    fun borrow_pool_info<C>(): (address, vector<u8>, vector<u8>, address) acquires PoolList {
        let key = coin_key::key<C>();
        let pool_list = borrow_global<PoolList>(permission::owner_address());
        let info = simple_map::borrow<String, PoolInfo>(&pool_list.infos, &key);
        (type_info::account_address(&info.type_info), type_info::module_name(&info.type_info), type_info::struct_name(&info.type_info), info.holder)
    }
    #[test(owner = @leizd)]
    fun test_initialize(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        assert!(exists<PoolList>(signer::address_of(owner)), 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_initialize_with_not_owner(account: &signer) {
        initialize(account);
    }
    #[test(owner = @leizd)]
    #[expected_failure(abort_code = 65537)]
    fun test_initialize_more_than_once(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        initialize(owner);
    }
    #[test(owner = @leizd)]
    fun test_add_pool_from_owner(owner: &signer) acquires PoolList, PoolManagerEventHandle {
        set_up(owner);

        initialize(owner);
        add_pool<WETH>(owner);
    }
    #[test(owner = @leizd, account = @0x111)]
    fun test_add_pool_from_not_owner(owner: &signer, account: &signer) acquires PoolList, PoolManagerEventHandle {
        set_up(owner);
        initialize(owner);
        account::create_account_for_test(signer::address_of(account));
        add_pool<USDC>(account);
    }
    #[test(owner = @leizd, account = @0x111)]
    fun test_add_pool_more_than_once(owner: &signer, account: &signer) acquires PoolList, PoolManagerEventHandle {
        let account_addr = signer::address_of(account);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(account_addr);
        set_up(owner);
        initialize(owner);
        add_pool<WETH>(account);
        add_pool<USDC>(owner);
        add_pool<USDT>(account);

        let (account_address, module_name, struct_name, holder) = borrow_pool_info<WETH>();
        assert!(account_address == @leizd, 0);
        assert!(module_name == b"test_coin", 0);
        assert!(struct_name == b"WETH", 0);
        assert!(holder == account_addr, 0);
        let (account_address, module_name, struct_name, holder) = borrow_pool_info<USDC>();
        assert!(account_address == @leizd, 0);
        assert!(module_name == b"test_coin", 0);
        assert!(struct_name == b"USDC", 0);
        assert!(holder == owner_addr, 0);
        let (account_address, module_name, struct_name, holder) = borrow_pool_info<USDT>();
        assert!(account_address == @leizd, 0);
        assert!(module_name == b"test_coin", 0);
        assert!(struct_name == b"USDT", 0);
        assert!(holder == account_addr, 0);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65538)]
    fun test_add_pool_with_same_coins(owner: &signer, account: &signer) acquires PoolList, PoolManagerEventHandle {
        set_up(owner);
        account::create_account_for_test(signer::address_of(account));

        initialize(owner);
        add_pool<WETH>(account);
        add_pool<WETH>(account);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_add_pool_with_not_initialized_coin(owner: &signer, account: &signer) acquires PoolList, PoolManagerEventHandle {
        set_up(owner);
        account::create_account_for_test(signer::address_of(account));

        initialize(owner);
        add_pool<UNI>(account);
    }
}
