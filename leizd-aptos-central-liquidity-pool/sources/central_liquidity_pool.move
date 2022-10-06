module leizd_aptos_central_liquidity_pool::central_liquidity_pool {

    use std::error;
    use std::signer;
    use std::vector;
    use std::string::{String};
    use aptos_std::simple_map;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::event;
    use leizd_aptos_common::permission;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd_aptos_central_liquidity_pool::stb_usdz;
    use leizd_aptos_treasury::treasury;
    use leizd_aptos_lib::math128;
    use leizd_aptos_lib::constant;

    //// error_code
    const EALREADY_INITIALIZED: u64 = 1;
    const EINVALID_PROTOCOL_FEE: u64 = 2;
    const EINVALID_AMOUNT: u64 = 3;
    const EEXCEED_REMAINING_AMOUNT: u64 = 4;
    const EEXCEED_DEPOSITED_AMOUNT: u64 = 5;
    const EALREADY_ADDED_COIN: u64 = 6;
    const ENOT_INITIALIZED_COIN: u64 = 7;
    const ENOT_ADDED_COIN: u64 = 8;
    const ENOT_SUPPORTED_COIN: u64 = 9;
    const EINVALID_SUPPORT_FEE: u64 = 10;

    const PRECISION: u64 = 1000000000;
    const DEFAULT_PROTOCOL_FEE: u64 = 1000000000 * 10 / 1000; // 1%
    const DEFAULT_SUPPORT_FEE: u64 = 1000000000 * 1 / 1000; // 0.1%

    //// resources
    /// access control
    struct OperatorKey has store, drop {}
    struct AssetManagerKey has store, drop {}

    struct CentralLiquidityPool has key {
        left: coin::Coin<USDZ>,
        total_deposited: u128,
        total_borrowed: u128,
        total_uncollected_fee: u128,
        supported_pools: vector<String>, // e.g. 0x1::module_name::WBTC
        protocol_fees: u64,
        harvested_protocol_fees: u64,
    }

    struct Balance has key {
        borrowed: simple_map::SimpleMap<String,u128>,
        uncollected_support_fee: simple_map::SimpleMap<String,u128>,
    }

    struct Config has key {
        protocol_fee: u64, // usage fee
        support_fee: u64, // base fee obtained from supported pools
    }

    // events
    struct DepositEvent has store, drop {
        caller: address,
        target_account: address,
        amount: u64,
        total_deposited: u128
    }
    struct WithdrawEvent has store, drop {
        caller: address,
        target_account: address,
        amount: u64,
        total_deposited: u128
    }
    struct BorrowEvent has store, drop {
        key: String,
        caller: address,
        target_account: address,
        amount: u64,
        total_borrowed: u128
    }
    struct RepayEvent has store, drop {
        key: String,
        caller: address,
        target_account: address,
        amount: u64,
        total_borrowed: u128
    }
    struct UpdateConfigEvent has store, drop {
        caller: address,
        protocol_fee: u64,
        support_fee: u64,
    }
    struct CentralLiquidityPoolEventHandle has key, store {
        deposit_event: event::EventHandle<DepositEvent>,
        withdraw_event: event::EventHandle<WithdrawEvent>,
        borrow_event: event::EventHandle<BorrowEvent>,
        repay_event: event::EventHandle<RepayEvent>,
        update_config_event: event::EventHandle<UpdateConfigEvent>,
    }

    ////////////////////////////////////////////////////
    /// Initialize
    ////////////////////////////////////////////////////
    public entry fun initialize(owner: &signer) acquires CentralLiquidityPoolEventHandle {
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);
        assert!(!is_pool_initialized(), error::invalid_state(EALREADY_INITIALIZED));

        stb_usdz::initialize(owner);
        move_to(owner, CentralLiquidityPool {
            left: coin::zero<USDZ>(),
            total_deposited: 0,
            total_borrowed: 0,
            total_uncollected_fee: 0,
            supported_pools: vector::empty<String>(),
            protocol_fees: 0,
            harvested_protocol_fees: 0
        });
        move_to(owner, Balance {
            borrowed: simple_map::create<String,u128>(),
            uncollected_support_fee: simple_map::create<String,u128>(),
        });
        move_to(owner, Config {
            protocol_fee: DEFAULT_PROTOCOL_FEE,
            support_fee: DEFAULT_SUPPORT_FEE
        });
        move_to(owner, CentralLiquidityPoolEventHandle {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
            update_config_event: account::new_event_handle<UpdateConfigEvent>(owner),
        });
        event::emit_event<UpdateConfigEvent>(
            &mut borrow_global_mut<CentralLiquidityPoolEventHandle>(owner_address).update_config_event,
            UpdateConfigEvent {
                caller: owner_address,
                protocol_fee: DEFAULT_PROTOCOL_FEE,
                support_fee: DEFAULT_SUPPORT_FEE
            }
        );
    }

    public fun is_pool_initialized(): bool {
        exists<CentralLiquidityPool>(permission::owner_address())
    }
    //// for assets
    public fun initialize_for_asset<C>(
        account: &signer,
        _key: &AssetManagerKey
    ) acquires Balance {
        initialize_for_asset_internal<C>(account);
    }
    fun initialize_for_asset_internal<C>(_account: &signer) acquires Balance {
        let balance = borrow_global_mut<Balance>(permission::owner_address());
        simple_map::add<String,u128>(&mut balance.borrowed, key<C>(), 0);
        simple_map::add<String,u128>(&mut balance.uncollected_support_fee, key<C>(), 0);
    }
    //// access control
    public fun publish_operator_key(owner: &signer): OperatorKey {
        permission::assert_owner(signer::address_of(owner));
        OperatorKey {}
    }
    public fun publish_asset_manager_key(owner: &signer): AssetManagerKey {
        permission::assert_owner(signer::address_of(owner));
        AssetManagerKey {}
    }

    public entry fun update_config(owner: &signer, new_protocol_fee: u64, new_support_fee: u64) acquires Config, CentralLiquidityPoolEventHandle {
        assert!(new_protocol_fee < PRECISION, error::invalid_argument(EINVALID_PROTOCOL_FEE));
        assert!(new_support_fee < PRECISION, error::invalid_argument(EINVALID_SUPPORT_FEE));
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);

        let config = borrow_global_mut<Config>(owner_address);
        if (config.protocol_fee == new_protocol_fee && config.support_fee == new_support_fee) return;
        config.protocol_fee = new_protocol_fee;
        config.support_fee = new_support_fee;

        event::emit_event<UpdateConfigEvent>(
            &mut borrow_global_mut<CentralLiquidityPoolEventHandle>(owner_address).update_config_event,
            UpdateConfigEvent {
                caller: owner_address,
                protocol_fee: new_protocol_fee,
                support_fee: new_support_fee,
            }
        );
    }

    public fun is_supported(key: String): bool acquires CentralLiquidityPool {
        let pool = borrow_global<CentralLiquidityPool>(permission::owner_address());
        is_supported_internal(pool, key)
    }
    fun is_supported_internal(pool: &CentralLiquidityPool, key: String): bool {
        vector::contains<String>(&pool.supported_pools, &key)
    }

    public entry fun add_supported_pool<C>(owner: &signer) acquires CentralLiquidityPool {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        let key = key<C>();
        assert!(coin::is_coin_initialized<C>(), error::invalid_argument(ENOT_INITIALIZED_COIN));
        assert!(!is_supported(key), error::invalid_argument(EALREADY_ADDED_COIN));
        let supported_pools = &mut borrow_global_mut<CentralLiquidityPool>(owner_addr).supported_pools;
        vector::push_back<String>(supported_pools, key);
    }

    public entry fun remove_supported_pool<C>(owner: &signer) acquires CentralLiquidityPool {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        let key = key<C>();
        assert!(is_supported(key), error::invalid_argument(ENOT_ADDED_COIN));
        let supported_pools = &mut borrow_global_mut<CentralLiquidityPool>(owner_addr).supported_pools;

        let i = vector::length<String>(supported_pools);
        while (i > 0) {
            i = i - 1;
            if (*vector::borrow<String>(supported_pools, i) == key) {
                break
            }
        };
        vector::remove<String>(supported_pools, i);
    }

    ////////////////////////////////////////////////////
    /// Deposit
    ////////////////////////////////////////////////////
    public entry fun deposit(account: &signer, amount: u64) acquires CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        let owner_address = permission::owner_address();
        let account_address = signer::address_of(account);
        let pool_ref = borrow_global_mut<CentralLiquidityPool>(owner_address);
        if (!stb_usdz::is_account_registered(account_address)) {
            stb_usdz::register(account);
        };
        let user_share = math128::to_share((amount as u128), pool_ref.total_deposited, stb_usdz::supply());
        stb_usdz::mint(account_address, (user_share as u64));
        pool_ref.total_deposited = pool_ref.total_deposited + (amount as u128);
        coin::merge(&mut pool_ref.left, coin::withdraw<USDZ>(account, amount));

        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<CentralLiquidityPoolEventHandle>(owner_address).deposit_event,
            DepositEvent {
                caller: account_address,
                target_account: account_address,
                amount,
                total_deposited: pool_ref.total_deposited
            }
        );
    }

    ////////////////////////////////////////////////////
    /// Withdraw
    ////////////////////////////////////////////////////
    public entry fun withdraw(account: &signer, amount: u64) acquires CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        let owner_address = permission::owner_address();
        let account_addr = signer::address_of(account);
        let pool_ref = borrow_global_mut<CentralLiquidityPool>(owner_address);
        let user_share = (stb_usdz::balance_of(account_addr) as u128);
        let withdrawable_amount = math128::to_amount(user_share, pool_ref.total_deposited, stb_usdz::supply());

        let burned_share: u128;
        let withdrawn_amount: u128;
        if (amount == constant::u64_max()) {
            burned_share = user_share;
            withdrawn_amount = withdrawable_amount;
        } else {
            assert!(withdrawable_amount >= (amount as u128), error::invalid_argument(EEXCEED_DEPOSITED_AMOUNT));
            burned_share = math128::to_share_roundup((amount as u128), pool_ref.total_deposited, stb_usdz::supply());
            withdrawn_amount = (amount as u128);
        };
        assert!((coin::value<USDZ>(&pool_ref.left) as u128) >= withdrawn_amount, error::invalid_argument(EEXCEED_REMAINING_AMOUNT));
        pool_ref.total_deposited = pool_ref.total_deposited - withdrawn_amount;
        coin::deposit(account_addr, coin::extract(&mut pool_ref.left, (withdrawn_amount as u64)));
        stb_usdz::burn(account, (burned_share as u64));
        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<CentralLiquidityPoolEventHandle>(owner_address).withdraw_event,
            WithdrawEvent {
                caller: account_addr,
                target_account: account_addr,
                amount: (withdrawn_amount as u64),
                total_deposited: pool_ref.total_deposited
            }
        );
    }

    ////////////////////////////////////////////////////
    /// Borrow
    ////////////////////////////////////////////////////
    public fun borrow(
        key: String,
        addr: address,
        amount: u64,
        _key: &OperatorKey
    ): (coin::Coin<USDZ>,u128) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        borrow_internal(key, addr, amount)
    }
    fun borrow_internal(key: String, addr: address, amount: u64): (coin::Coin<USDZ>,u128) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        assert!(is_supported(key), error::invalid_argument(ENOT_SUPPORTED_COIN));
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<CentralLiquidityPool>(owner_address);
        let balance_ref = borrow_global_mut<Balance>(owner_address);
        assert!(coin::value<USDZ>(&pool_ref.left) >= amount, error::invalid_argument(EEXCEED_REMAINING_AMOUNT));

        let borrowed = simple_map::borrow_mut<String,u128>(&mut balance_ref.borrowed, &key);
        *borrowed = *borrowed + (amount as u128);
        pool_ref.total_borrowed = pool_ref.total_borrowed + (amount as u128);

        let borrowed = coin::extract<USDZ>(&mut pool_ref.left, amount);
        let total_borrowed = pool_ref.total_borrowed;
        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<CentralLiquidityPoolEventHandle>(permission::owner_address()).borrow_event,
            BorrowEvent {
                key,
                caller: addr,
                target_account: addr,
                amount,
                total_borrowed
            }
        );
        (borrowed, total_borrowed)
    }
    public fun protocol_fee(): u64 acquires Config {
        borrow_global<Config>(permission::owner_address()).protocol_fee
    }
    public fun calculate_protocol_fee(value: u128): u128 acquires Config {
        calculate_fee_with_round_up(value, (protocol_fee() as u128))
    }
    public fun support_fee(): u64 acquires Config {
        borrow_global<Config>(permission::owner_address()).support_fee
    }
    public fun calculate_support_fee(value: u128): u128 acquires Config {
        calculate_fee_with_round_up(value, (support_fee() as u128))
    }
    //// for round up
    fun calculate_fee_with_round_up(value: u128, fee: u128): u128 {
        let value_mul_by_fee = value * fee;
        let result = value_mul_by_fee / (PRECISION as u128);
        if (value_mul_by_fee % (PRECISION as u128) != 0) result + 1 else result
    }

    ////////////////////////////////////////////////////
    /// Repay
    ////////////////////////////////////////////////////
    public fun repay(
        key: String,
        account: &signer,
        amount: u64,
        _key: &OperatorKey
    ) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        repay_internal(key, account, amount);
    }
    fun repay_internal(key: String, account: &signer, amount: u64) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        let owner_address = permission::owner_address();
        let balance_ref = borrow_global_mut<Balance>(owner_address);
        let borrowed = simple_map::borrow_mut<String,u128>(&mut balance_ref.borrowed, &key);
        assert!((amount as u128) <= *borrowed, error::invalid_argument(EINVALID_AMOUNT));

        *borrowed = *borrowed - (amount as u128);
        let pool_ref = borrow_global_mut<CentralLiquidityPool>(owner_address);
        pool_ref.total_borrowed = pool_ref.total_borrowed - (amount as u128);
        coin::merge<USDZ>(&mut pool_ref.left, coin::withdraw<USDZ>(account, amount));

        let account_addr = signer::address_of(account);
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<CentralLiquidityPoolEventHandle>(permission::owner_address()).repay_event,
            RepayEvent {
                key,
                caller: account_addr,
                target_account: account_addr,
                amount: amount,
                total_borrowed: pool_ref.total_borrowed
            }
        );
    }

    public fun accrue_interest(key: String, interest: u128, _key: &OperatorKey) acquires Balance, CentralLiquidityPool, Config {
        accrue_interest_internal(key, interest)
    }
    fun accrue_interest_internal(key: String, interest: u128) acquires Balance, CentralLiquidityPool, Config {
        let owner_address = permission::owner_address();
        let balance_ref = borrow_global_mut<Balance>(owner_address);
        let pool_ref = borrow_global_mut<CentralLiquidityPool>(owner_address);
        let protocol_fee = calculate_protocol_fee(interest);
        let depositors_share = interest - protocol_fee;

        let borrowed = simple_map::borrow_mut<String,u128>(&mut balance_ref.borrowed, &key);
        *borrowed = *borrowed + interest;
        pool_ref.total_borrowed = pool_ref.total_borrowed + interest;
        pool_ref.total_deposited = pool_ref.total_deposited + depositors_share;
        pool_ref.protocol_fees = pool_ref.protocol_fees + (protocol_fee as u64);
    }

    public fun collect_support_fee(
        key: String,
        coin: coin::Coin<USDZ>,
        new_uncollected_fee: u128,
        _key: &OperatorKey
    ) acquires CentralLiquidityPool, Balance {
        collect_support_fee_internal(key, coin, new_uncollected_fee)
    }
    fun collect_support_fee_internal(key: String, coin: coin::Coin<USDZ>, new_uncollected_fee: u128) acquires CentralLiquidityPool, Balance {
        let owner_address = permission::owner_address();
        let balance_ref = borrow_global_mut<Balance>(owner_address);
        let pool_ref = borrow_global_mut<CentralLiquidityPool>(owner_address);

        let uncollected_support_fee = simple_map::borrow_mut<String,u128>(&mut balance_ref.uncollected_support_fee, &key);
        pool_ref.total_uncollected_fee = pool_ref.total_uncollected_fee - *uncollected_support_fee;
        *uncollected_support_fee = new_uncollected_fee;
        pool_ref.total_uncollected_fee = pool_ref.total_uncollected_fee + new_uncollected_fee;
        pool_ref.total_deposited = pool_ref.total_deposited + (coin::value<USDZ>(&coin) as u128);
        coin::merge<USDZ>(&mut pool_ref.left, coin);
    }

    public fun harvest_protocol_fees<C>() acquires CentralLiquidityPool {
        let pool_ref = borrow_global_mut<CentralLiquidityPool>(permission::owner_address());
        let harvested_fee = (pool_ref.protocol_fees - pool_ref.harvested_protocol_fees as u128);
        if(harvested_fee == 0){
            return
        };
        let liquidity = (coin::value<USDZ>(&pool_ref.left) as u128);
        if(harvested_fee > liquidity){
            harvested_fee = liquidity;
        };
        pool_ref.harvested_protocol_fees = pool_ref.harvested_protocol_fees + (harvested_fee as u64);
        let fee_extracted = coin::extract(&mut pool_ref.left, (harvested_fee as u64));
        treasury::collect_fee<USDZ>(fee_extracted);
    }

    ////// View functions
    public fun left(): u128 acquires CentralLiquidityPool {
        (coin::value<USDZ>(&borrow_global<CentralLiquidityPool>(permission::owner_address()).left) as u128)
    }

    public fun total_deposited(): u128 acquires CentralLiquidityPool {
        borrow_global<CentralLiquidityPool>(permission::owner_address()).total_deposited
    }

    public fun total_borrowed(): u128 acquires CentralLiquidityPool {
        borrow_global<CentralLiquidityPool>(permission::owner_address()).total_borrowed
    }

    public fun total_uncollected_fee(): u128 acquires CentralLiquidityPool {
        borrow_global<CentralLiquidityPool>(permission::owner_address()).total_uncollected_fee
    }

    public fun borrowed(key: String): u128 acquires Balance {
        let balance_ref = borrow_global<Balance>(permission::owner_address());
        *simple_map::borrow<String,u128>(&balance_ref.borrowed, &key)
    }

    public fun uncollected_support_fee(key: String): u128 acquires Balance {
        let balance_ref = borrow_global<Balance>(permission::owner_address());
        *simple_map::borrow<String,u128>(&balance_ref.uncollected_support_fee, &key)
    }

    // #[test_only]
    // use aptos_framework::debug;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_trove::usdz;
    #[test_only]
    use leizd_aptos_trove::trove_manager;
    #[test_only]
    use leizd_aptos_common::test_coin::{Self,WETH,USDC};
    #[test_only]
    public fun default_support_fee(): u64 {
        DEFAULT_SUPPORT_FEE
    }
    #[test_only]
    fun initialize_for_test_to_use_coin(owner: &signer) acquires Balance, CentralLiquidityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);

        trove_manager::initialize(owner);
        initialize(owner);

        test_coin::init_weth(owner);
        initialize_for_asset_internal<WETH>(owner);
    }
    // related initialize
    #[test(owner=@leizd_aptos_central_liquidity_pool)]
    public entry fun test_initialize(owner: &signer) acquires CentralLiquidityPool, Config, CentralLiquidityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        trove_manager::initialize(owner);

        initialize(owner);

        assert!(exists<CentralLiquidityPool>(owner_addr), 0);
        let central_liquidity_pool_ref = borrow_global<CentralLiquidityPool>(owner_addr);
        assert!(central_liquidity_pool_ref.total_deposited == 0, 0);
        assert!(central_liquidity_pool_ref.total_borrowed == 0, 0);
        assert!(central_liquidity_pool_ref.total_uncollected_fee == 0, 0);

        assert!(exists<Config>(owner_addr), 0);
        let config_ref = borrow_global<Config>(owner_addr);
        assert!(config_ref.support_fee == DEFAULT_SUPPORT_FEE, 0);

        assert!(exists<CentralLiquidityPoolEventHandle>(owner_addr), 0);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool)]
    #[expected_failure(abort_code = 196609)]
    public entry fun test_initialize_twice(owner: &signer) acquires CentralLiquidityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        trove_manager::initialize(owner);

        initialize(owner);
        initialize(owner);
    }
    #[test(account=@0x111)]
    #[expected_failure(abort_code = 65537)]
    public entry fun test_initialize_without_owner(account: &signer) acquires CentralLiquidityPoolEventHandle {
        initialize(account);
    }
    #[test(owner = @leizd_aptos_central_liquidity_pool)]
    fun test_is_supported(owner: &signer) acquires CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        trove_manager::initialize(owner);
        initialize(owner);

        test_coin::init_weth(owner);
        test_coin::init_usdc(owner);
        assert!(!is_supported(key<WETH>()), 0);
        assert!(!is_supported(key<USDC>()), 0);

        add_supported_pool<WETH>(owner);
        assert!(is_supported(key<WETH>()), 0);
        assert!(!is_supported(key<USDC>()), 0);

        remove_supported_pool<WETH>(owner);
        assert!(!is_supported(key<WETH>()), 0);
        assert!(!is_supported(key<USDC>()), 0);

        add_supported_pool<WETH>(owner);
        add_supported_pool<USDC>(owner);
        assert!(is_supported(key<WETH>()), 0);
        assert!(is_supported(key<USDC>()), 0);

        remove_supported_pool<WETH>(owner);
        remove_supported_pool<USDC>(owner);
        assert!(!is_supported(key<WETH>()), 0);
        assert!(!is_supported(key<USDC>()), 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_add_supported_pool_with_not_owner(account: &signer) acquires CentralLiquidityPool {
        add_supported_pool<WETH>(account)
    }
    #[test(owner = @leizd_aptos_central_liquidity_pool)]
    #[expected_failure(abort_code = 65543)]
    fun test_add_supported_pool_with_not_initialized_coin(owner: &signer) acquires CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        trove_manager::initialize(owner);
        initialize(owner);

        add_supported_pool<WETH>(owner);
    }
    #[test(owner = @leizd_aptos_central_liquidity_pool)]
    #[expected_failure(abort_code = 65542)]
    fun test_add_supported_pool_if_already_added(owner: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        assert!(!is_supported(key<WETH>()), 0);

        add_supported_pool<WETH>(owner);
        add_supported_pool<WETH>(owner);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_remove_supported_pool_with_not_owner(account: &signer) acquires CentralLiquidityPool {
        remove_supported_pool<WETH>(account)
    }
    #[test(owner = @leizd_aptos_central_liquidity_pool)]
    #[expected_failure(abort_code = 65544)]
    fun test_add_supported_pool_if_already_removed(owner: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        assert!(!is_supported(key<WETH>()), 0);

        remove_supported_pool<WETH>(owner);
    }
    // for deposit
    #[test(owner=@leizd_aptos_central_liquidity_pool,account=@0x111)]
    public entry fun test_deposit(owner: &signer, account: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit(account, 400000);
        assert!(left() == 400000, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(usdz::balance_of(account_addr) == 600000, 0);
        assert!(stb_usdz::balance_of(account_addr) == 400000, 0);

        assert!(event::counter<DepositEvent>(&borrow_global<CentralLiquidityPoolEventHandle>(signer::address_of(owner)).deposit_event) == 1, 0);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool,account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_deposit_with_no_amount(owner: &signer, account: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit(account, 0);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool,account=@0x111)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_deposit_with_not_enough_coin(owner: &signer, account: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000);

        deposit(account, 1001);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool, account=@0x111)]
    public entry fun test_deposit_more_than_once_sequentially(owner: &signer, account: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000);

        deposit(account, 100);
        assert!(usdz::balance_of(account_addr) == 900, 0);
        assert!(stb_usdz::balance_of(account_addr) == 100, 0);
        deposit(account, 200);
        assert!(usdz::balance_of(account_addr) == 700, 0);
        assert!(stb_usdz::balance_of(account_addr) == 300, 0);
        deposit(account, 300);
        assert!(usdz::balance_of(account_addr) == 400, 0);
        assert!(stb_usdz::balance_of(account_addr) == 600, 0);
        deposit(account, 400);
        assert!(usdz::balance_of(account_addr) == 0, 0);
        assert!(stb_usdz::balance_of(account_addr) == 1000, 0);
    }

    // for withdraw
    #[test(owner=@leizd_aptos_central_liquidity_pool,account=@0x111)]
    public entry fun test_withdraw(owner: &signer, account: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit(account, 400000);

        withdraw(account, 300000);
        assert!(left() == 100000, 0);
        assert!(total_deposited() == 100000, 0);
        assert!(usdz::balance_of(account_addr) == 900000, 0);
        assert!(stb_usdz::balance_of(account_addr) == 100000, 0);

        assert!(event::counter<WithdrawEvent>(&borrow_global<CentralLiquidityPoolEventHandle>(signer::address_of(owner)).withdraw_event) == 1, 0);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool,account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_withdraw_with_no_amount(owner: &signer, account: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit(account, 400000);
        withdraw(account, 0);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool,account1=@0x111,account2=@0x222)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_withdraw_without_any_deposit(owner: &signer, account1: &signer, account2: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        managed_coin::register<USDZ>(account1);
        managed_coin::register<USDZ>(account2);
        stb_usdz::register(account2);
        usdz::mint_for_test(account1_addr, 400000);

        deposit(account1, 400000);
        withdraw(account2, 300000);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool,account=@0x111)]
    public entry fun test_withdraw_with_amount_is_total_deposited(owner: &signer, account: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 300000);

        deposit(account, 300000);
        withdraw(account, 300000);

        assert!(usdz::balance_of(account_addr) == 300000, 0);
        assert!(stb_usdz::balance_of(account_addr) == 0, 0);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool,account=@0x111)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_withdraw_with_amount_is_greater_than_total_deposited(owner: &signer, account: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 300000);

        deposit(account, 300000);
        withdraw(account, 300001);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool, account=@0x111)]
    public entry fun test_withdraw_more_than_once_sequentially(owner: &signer, account: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000);

        deposit(account, 1000);
        withdraw(account, 100);
        assert!(usdz::balance_of(account_addr) == 100, 0);
        assert!(stb_usdz::balance_of(account_addr) == 900, 0);
        withdraw(account, 200);
        assert!(usdz::balance_of(account_addr) == 300, 0);
        assert!(stb_usdz::balance_of(account_addr) == 700, 0);
        withdraw(account, 300);
        assert!(usdz::balance_of(account_addr) == 600, 0);
        assert!(stb_usdz::balance_of(account_addr) == 400, 0);
        withdraw(account, 400);
        assert!(usdz::balance_of(account_addr) == 1000, 0);
        assert!(stb_usdz::balance_of(account_addr) == 0, 0);
    }

    // for borrow
    #[test(owner=@leizd_aptos_central_liquidity_pool,account1=@0x111,account2=@0x222)]
    public entry fun test_borrow(owner: &signer, account1: &signer, account2: &signer) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);
        managed_coin::register<USDZ>(account2);

        // execute
        deposit(account1, 400000);
        let (borrowed, _) = borrow_internal(key<WETH>(), account1_addr, 300000);
        coin::deposit(account2_addr, borrowed);

        // assertions
        assert!(total_deposited() == 400000, 0);
        assert!(left() == 100000, 0);
        assert!(total_borrowed() == (300000 as u128), 0);
        assert!(borrowed(key<WETH>()) == (300000 as u128), 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
        assert!(usdz::balance_of(account2_addr) == 300000, 0);
        //// event
        assert!(event::counter<BorrowEvent>(&borrow_global<CentralLiquidityPoolEventHandle>(signer::address_of(owner)).borrow_event) == 1, 0);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool, account=@0x111)]
    #[expected_failure(abort_code = 65545)]
    public entry fun test_borrow_with_not_supported_coin(owner: &signer, account: &signer) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        trove_manager::initialize(owner);
        initialize(owner);

        let account_addr = signer::address_of(account);
        let (coin, _) = borrow_internal(key<WETH>(), account_addr, 0);

        // post_process
        coin::deposit(account_addr, coin);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool, account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_borrow_with_no_amount(owner: &signer, account: &signer) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);

        let (coin, _) = borrow_internal(key<WETH>(), account_addr, 0);

        // post_process
        coin::deposit(account_addr, coin);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool, account=@0x111)]
    #[expected_failure(abort_code = 65540)]
    public entry fun test_borrow_with_amount_is_greater_than_left(owner: &signer, account: &signer) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);

        let (coin, _) = borrow_internal(key<WETH>(), account_addr, 1001);

        // post_process
        coin::deposit(account_addr, coin);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool,depositor=@0x111,borrower=@0x222)]
    public entry fun test_borrow_more_than_once_sequentially(owner: &signer, depositor: &signer, borrower: &signer) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);

        managed_coin::register<USDZ>(depositor);
        usdz::mint_for_test(depositor_addr, 1000000);
        managed_coin::register<USDZ>(borrower);

        // execute
        deposit(depositor, 400000);
        assert!(total_deposited() == 400000, 0);

        let (borrowed, _) = borrow_internal(key<WETH>(), depositor_addr, 100000);
        assert!(left() == 300000, 0);
        assert!(total_borrowed() == (100000 as u128), 0);
        assert!(borrowed(key<WETH>()) == (100000 as u128), 0);
        coin::deposit(borrower_addr, borrowed);

        let (borrowed, _) = borrow_internal(key<WETH>(), depositor_addr, 100000);
        assert!(left() == 200000, 0);
        assert!(total_borrowed() == (200000 as u128), 0);
        assert!(borrowed(key<WETH>()) == (200000 as u128), 0);
        coin::deposit(borrower_addr, borrowed);

        let (borrowed, _) = borrow_internal(key<WETH>(), depositor_addr, 100000);
        assert!(left() == 100000, 0);
        assert!(total_borrowed() == (300000 as u128), 0);
        assert!(borrowed(key<WETH>()) == (300000 as u128), 0);
        coin::deposit(borrower_addr, borrowed);

        let (borrowed, _) = borrow_internal(key<WETH>(), depositor_addr, 100000);
        assert!(left() == 0, 0);
        assert!(total_borrowed() == (400000 as u128), 0);
        assert!(borrowed(key<WETH>()) == (400000 as u128), 0);
        coin::deposit(borrower_addr, borrowed);
    }

    // for repay
    #[test(owner=@leizd_aptos_central_liquidity_pool,account1=@0x111,account2=@0x222)]
    public entry fun test_repay(owner: &signer, account1: &signer, account2: &signer) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);
        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);
        managed_coin::register<USDZ>(account2);

        // execute
        deposit(account1, 400000);
        let (borrowed, _) = borrow_internal(key<WETH>(), account2_addr, 300000);
        coin::deposit(account2_addr, borrowed);
        repay_internal(key<WETH>(), account2, 200000);

        // check
        assert!(left() == (298500 + 1500), 0);
        assert!(total_deposited() == 400000, 0);
        assert!(total_borrowed() == 100000, 0);
        assert!(borrowed(key<WETH>()) == 100000, 0);
        assert!(usdz::balance_of(account2_addr) == 100000, 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
        //// event
        assert!(event::counter<RepayEvent>(&borrow_global<CentralLiquidityPoolEventHandle>(signer::address_of(owner)).repay_event) == 1, 0);
    }
    //// validations
    #[test(owner=@leizd_aptos_central_liquidity_pool,account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_repay_with_zero_amount(owner: &signer, account: &signer) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        repay_internal(key<WETH>(), account, 0);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool,account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_repay_with_amount_is_greater_than_total_borrowed(owner: &signer, account: &signer) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let owner_addr = signer::address_of(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(owner);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(owner_addr, 2000);

        // execute
        deposit(owner, 2000);
        let (borrowed, _) = borrow_internal(key<WETH>(), owner_addr, 1000);
        repay_internal(key<WETH>(), account, 1005 + 1);

        // post_process
        coin::deposit(owner_addr, borrowed);
    }
    //// calculation
    #[test(owner=@leizd_aptos_central_liquidity_pool,depositor=@0x111,borrower=@0x222)]
    public entry fun test_repay_for_confirming_priority(owner: &signer, depositor: &signer, borrower: &signer) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        usdz::mint_for_test(depositor_addr, 10000);
        managed_coin::register<USDZ>(borrower);

        // execute
        //// add liquidity & borrow
        deposit(depositor, 10000);
        let (borrowed, _) = borrow_internal(key<WETH>(), borrower_addr, 10000);
        coin::deposit(borrower_addr, borrowed);
        assert!(total_deposited() == 10000, 0);
        assert!(left() == 0, 0);
        assert!(total_borrowed() == 10000, 0);
        assert!(borrowed(key<WETH>()) == 10000, 0);
        assert!(stb_usdz::balance_of(depositor_addr) == 10000, 0);
        assert!(usdz::balance_of(borrower_addr) == 10000, 0);
        //// repay to total_borrowed
        repay_internal(key<WETH>(), borrower, 9900);
        assert!(left() == 9900, 0);
        assert!(total_borrowed() == 100, 0);
        assert!(borrowed(key<WETH>()) == 100, 0);
        assert!(total_uncollected_fee() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 100, 0);
        ////// repay to remained total_borrowed
        repay_internal(key<WETH>(), borrower, 100);
        assert!(left() == 10000, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed(key<WETH>()) == 0, 0);
        assert!(total_uncollected_fee() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd_aptos_central_liquidity_pool,depositor=@0x111,borrower=@0x222)]
    public entry fun test_repay_with_amount_between_total_borrowed_and_uncollected_fee(owner: &signer, depositor: &signer, borrower: &signer) acquires CentralLiquidityPool, Balance, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        usdz::mint_for_test(depositor_addr, 10000);
        managed_coin::register<USDZ>(borrower);

        // execute
        //// add liquidity & borrow
        deposit(depositor, 10000);
        let (borrowed, _) = borrow_internal(key<WETH>(), borrower_addr, 10000);
        coin::deposit(borrower_addr, borrowed);
        assert!(total_deposited() == 10000, 0);
        assert!(left() == 0, 0);
        assert!(total_borrowed() == 10000, 0);
        assert!(borrowed(key<WETH>()) == 10000, 0);
        assert!(total_uncollected_fee() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 10000, 0);
        //// repay
        repay_internal(key<WETH>(), borrower, 100);
        assert!(left() == 100, 0);
        assert!(total_borrowed() == 9900, 0);
        assert!(borrowed(key<WETH>()) == 9900, 0);
        assert!(total_uncollected_fee() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 9900, 0);
    }

    //// related functions
    // for related configuration
    #[test(owner = @leizd_aptos_central_liquidity_pool)]
    fun test_update_config(owner: &signer) acquires Balance, Config, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);

        update_config(owner, PRECISION * 10 / 1000, PRECISION * 10 / 1000);
        assert!(protocol_fee() == PRECISION * 10 / 1000, 0);
        assert!(support_fee() == PRECISION * 10 / 1000, 0);

        assert!(event::counter<UpdateConfigEvent>(&borrow_global<CentralLiquidityPoolEventHandle>(signer::address_of(owner)).update_config_event) == 2, 0);
    }
    #[test(owner = @leizd_aptos_central_liquidity_pool, account = @0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_update_config_with_not_owner(owner: &signer, account: &signer) acquires Balance, Config, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        update_config(account, PRECISION * 10 / 1000, PRECISION * 10 / 1000);
    }
    #[test(owner = @leizd_aptos_central_liquidity_pool)]
    #[expected_failure(abort_code = 65538)]
    fun test_update_config_with_protocol_fee_as_equal_to_precision(owner: &signer) acquires Balance, Config, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        update_config(owner, PRECISION, support_fee());
    }
    #[test(owner = @leizd_aptos_central_liquidity_pool)]
    #[expected_failure(abort_code = 65546)]
    fun test_update_config_with_support_fee_as_equal_to_precision(owner: &signer) acquires Balance, Config, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        update_config(owner, protocol_fee(), PRECISION);
    }
    #[test(owner = @leizd_aptos_central_liquidity_pool)]
    fun test_calculate_support_fee(owner: &signer) acquires Balance, Config, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);

        assert!(calculate_support_fee(100000) == 100, 0);
        assert!(calculate_support_fee(100001) == 101, 0);
        assert!(calculate_support_fee(99999) == 100, 0);
        assert!(calculate_support_fee(2000) == 2, 0);
        assert!(calculate_support_fee(1990) == 2, 0);
        assert!(calculate_support_fee(1) == 1, 0);
        assert!(calculate_support_fee(0) == 0, 0);

        update_config(owner, protocol_fee(), PRECISION * 7 / 1000);
        assert!(calculate_support_fee(100001) == 701, 0);
        assert!(calculate_support_fee(100000) == 700, 0);
        assert!(calculate_support_fee(99999) == 700, 0);
        assert!(calculate_support_fee(143) == 2, 0);
        assert!(calculate_support_fee(142) == 1, 0);
        assert!(calculate_support_fee(1) == 1, 0);
        assert!(calculate_support_fee(0) == 0, 0);

        update_config(owner, protocol_fee(), 0);
        assert!(calculate_support_fee(100000) == 0, 0);
        assert!(calculate_support_fee(1) == 0, 0);
    }

    #[test(owner=@leizd_aptos_central_liquidity_pool, account1=@0x111, account2=@0x222)]
    public entry fun test_deposit_and_withdraw_without_fees(owner: &signer, account1: &signer, account2: &signer) acquires Balance, CentralLiquidityPool, CentralLiquidityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr1 = signer::address_of(account1);
        let account_addr2 = signer::address_of(account2);
        account::create_account_for_test(account_addr1);
        account::create_account_for_test(account_addr2);

        managed_coin::register<USDZ>(account1);
        managed_coin::register<USDZ>(account2);
        usdz::mint_for_test(account_addr1, 1000);
        usdz::mint_for_test(account_addr2, 1000);

        // account1 deposit
        deposit(account1, 1000);
        assert!(usdz::balance_of(account_addr1) == 0, 0);
        assert!(total_deposited() == 1000, 0);
        assert!(left() == 1000, 0);
        assert!(stb_usdz::balance_of(account_addr1) == 1000, 0);
        assert!(stb_usdz::supply() == 1000, 0);

        // account1 withdraw half amount
        withdraw(account1, 500);
        assert!(usdz::balance_of(account_addr1) == 500, 0);
        assert!(total_deposited() == 500, 0);
        assert!(left() == 500, 0);
        assert!(stb_usdz::balance_of(account_addr1) == 500, 0);
        assert!(stb_usdz::supply() == 500, 0);

        // account2 deposit
        deposit(account2, 1000);
        assert!(usdz::balance_of(account_addr2) == 0, 0);
        assert!(total_deposited() == 1500, 0);
        assert!(left() == 1500, 0);
        assert!(stb_usdz::balance_of(account_addr2) == (1000 * 500 / 500), 0);
        assert!(stb_usdz::supply() == 1500, 0);

        // // account2 withdraw all
        withdraw(account2, constant::u64_max());
        assert!(usdz::balance_of(account_addr2) == 1000, 0);
        assert!(total_deposited() == 500, 0);
        assert!(left() == 500, 0);
        assert!(stb_usdz::balance_of(account_addr2) == 0, 0);
        assert!(stb_usdz::supply() == 500, 0);
    }
}
