/// Main point of interaction with Leizd Protocol
/// Users can:
/// # Deposit
/// # Withdraw
/// # Borrow
/// # Repay
/// # Liquidate
/// # Rebalance
module leizd::asset_pool {

    use std::error;
    use std::signer;
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::simple_map;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::permission;
    use leizd_aptos_common::pool_status;
    use leizd_aptos_external::dex_facade;
    use leizd_aptos_lib::math128;
    use leizd_aptos_logic::risk_factor;
    use leizd_aptos_treasury::treasury;
    use leizd::interest_rate;
    use leizd::central_liquidity_pool;

    friend leizd::pool_manager;

    //// error_code
    const ENOT_INITILIZED: u64 = 1;
    const EIS_ALREADY_EXISTED: u64 = 2;
    const EIS_NOT_EXISTED: u64 = 3;
    const EDEX_DOES_NOT_HAVE_LIQUIDITY: u64 = 4;
    const ENOT_AVAILABLE_STATUS: u64 = 5;
    const EAMOUNT_ARG_IS_ZERO: u64 = 11;
    const EINSUFFICIENT_LIQUIDITY: u64 = 12;
    const EINSUFFICIENT_CONLY_DEPOSITED: u64 = 13;

    struct AssetPoolKey has store, drop {} // TODO: remove `drop` ability

    /// Asset Pool where users can deposit and borrow.
    /// Each asset is separately deposited into a pool.
    struct Pool<phantom C> has key {
        asset: coin::Coin<C>,
    }

    struct Storage has key {
        assets: simple_map::SimpleMap<String, AssetStorage>,
    }

    /// The total deposit amount and total borrowed amount can be updated
    /// in this struct. The collateral only asset is separately managed
    /// to calculate the borrowable amount in the pool.
    /// C: The coin type of the pool e.g. WETH / APT / USDC
    /// NOTE: difference xxx_amount and xxx_share
    ///   `amount` is total deposited including interest (so basically always increasing by accrue_interest in all action)
    ///   `share` is user's proportional share to calculate amount to withdraw from total deposited `amount`
    ///    therefore, when calculating the latest available capacity, calculate after converting user's `share` to user's `amount`
    struct AssetStorage has store {
        total_normal_deposited_amount: u128, // borrowable
        total_normal_deposited_share: u128, // borrowable
        total_conly_deposited_amount: u128, // collateral only
        total_conly_deposited_share: u128, // collateral only
        total_borrowed_amount: u128,
        total_borrowed_share: u128,
        last_updated: u64,
        protocol_fees: u64,
        harvested_protocol_fees: u64,
        rcomp: u128,
    }

    // Events
    struct DepositEvent has store, drop {
        caller: address,
        receiver: address,
        amount: u64,
        is_collateral_only: bool,
    }
    struct WithdrawEvent has store, drop {
        caller: address,
        receiver: address,
        amount: u64,
        is_collateral_only: bool,
    }
    struct BorrowEvent has store, drop {
        caller: address,
        borrower: address,
        receiver: address,
        amount: u64,
    }
    struct RepayEvent has store, drop {
        caller: address,
        repay_target: address,
        amount: u64,
    }
    struct LiquidateEvent has store, drop {
        caller: address,
        target: address,
    }
    struct SwitchCollateralEvent has store, drop {
        caller: address,
        amount: u64,
        to_collateral_only: bool,
    }
    struct PoolEventHandle<phantom C> has key, store {
        deposit_event: event::EventHandle<DepositEvent>,
        withdraw_event: event::EventHandle<WithdrawEvent>,
        borrow_event: event::EventHandle<BorrowEvent>,
        repay_event: event::EventHandle<RepayEvent>,
        liquidate_event: event::EventHandle<LiquidateEvent>,
        switch_collateral_event: event::EventHandle<SwitchCollateralEvent>,
    }

    // initialize
    public entry fun initialize(owner: &signer): AssetPoolKey {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        assert!(!exists<Storage>(owner_addr), error::invalid_argument(EIS_ALREADY_EXISTED));
        move_to(owner, Storage {
            assets: simple_map::create<String, AssetStorage>(),
        });
        AssetPoolKey {}
    }
    //// for assets
    /// Initializes a pool with the coin the owner specifies.
    /// The caller is only owner and creates not only a pool but also other resources
    /// such as a treasury for the coin, an interest rate model, and coins of collaterals and debts.
    public fun init_pool<C>(owner: &signer) acquires Storage {
        init_pool_internal<C>(owner);
    }

    fun init_pool_internal<C>(owner: &signer) acquires Storage {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        assert!(exists<Storage>(owner_addr), error::invalid_argument(ENOT_INITILIZED));
        assert!(!is_pool_initialized<C>(), error::invalid_argument(EIS_ALREADY_EXISTED));
        assert!(dex_facade::has_liquidity<C>(), error::invalid_state(EDEX_DOES_NOT_HAVE_LIQUIDITY));

        treasury::add_coin<C>(owner);
        risk_factor::new_asset<C>(owner);
        interest_rate::initialize<C>(owner);
        central_liquidity_pool::init_pool<C>(owner);
        pool_status::initialize<C>(owner);

        move_to(owner, Pool<C> {
            asset: coin::zero<C>()
        });
        let storage_ref = borrow_global_mut<Storage>(owner_addr);
        simple_map::add<String, AssetStorage>(&mut storage_ref.assets, key<C>(), default_asset_storage());
        move_to(owner, PoolEventHandle<C> {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
            liquidate_event: account::new_event_handle<LiquidateEvent>(owner),
            switch_collateral_event: account::new_event_handle<SwitchCollateralEvent>(owner),
        });
    }
    fun default_asset_storage(): AssetStorage {
        AssetStorage {
            total_normal_deposited_amount: 0,
            total_normal_deposited_share: 0,
            total_conly_deposited_amount: 0,
            total_conly_deposited_share: 0,
            total_borrowed_amount: 0,
            total_borrowed_share: 0,
            last_updated: 0,
            protocol_fees: 0,
            harvested_protocol_fees: 0,
            rcomp: 0,
        }
    }

    /// Deposits an asset or a shadow to the pool.
    /// If a user wants to protect the asset, it's possible that it can be used only for the collateral.
    /// C is a pool type and a user should select which pool to use.
    /// e.g. Deposit USDZ for WETH Pool -> deposit_for<WETH,Shadow>(x,x,x,x)
    /// e.g. Deposit WBTC for WBTC Pool -> deposit_for<WBTC,Asset>(x,x,x,x)
    public fun deposit_for<C>(
        account: &signer,
        for_address: address,
        amount: u64,
        is_collateral_only: bool,
        _key: &AssetPoolKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        deposit_for_internal<C>(
            account,
            for_address,
            amount,
            is_collateral_only
        )
    }

    fun deposit_for_internal<C>(
        account: &signer,
        for_address: address, // only use for event
        amount: u64,
        is_collateral_only: bool,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_deposit<C>(), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_address));

        accrue_interest<C>(asset_storage_ref);

        let user_share_u128: u128;
        coin::merge(&mut pool_ref.asset, coin::withdraw<C>(account, amount));
        if (is_collateral_only) {
            user_share_u128 = math128::to_share((amount as u128), asset_storage_ref.total_conly_deposited_amount, asset_storage_ref.total_conly_deposited_share);
            asset_storage_ref.total_conly_deposited_amount = asset_storage_ref.total_conly_deposited_amount + (amount as u128);
            asset_storage_ref.total_conly_deposited_share = asset_storage_ref.total_conly_deposited_share + user_share_u128;
        } else {
            user_share_u128 = math128::to_share((amount as u128), asset_storage_ref.total_normal_deposited_amount, asset_storage_ref.total_normal_deposited_share);
            asset_storage_ref.total_normal_deposited_amount = asset_storage_ref.total_normal_deposited_amount + (amount as u128);
            asset_storage_ref.total_normal_deposited_share = asset_storage_ref.total_normal_deposited_share + user_share_u128;
        };
        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).deposit_event,
            DepositEvent {
                caller: signer::address_of(account),
                receiver: for_address,
                amount,
                is_collateral_only,
            },
        );

        (amount, (user_share_u128 as u64))
    }

    /// Withdraws an asset or a shadow from the pool.
    public fun withdraw_for<C>(
        caller_addr: address,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool,
        _key: &AssetPoolKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        withdraw_for_internal<C>(
            caller_addr,
            receiver_addr,
            amount,
            is_collateral_only,
            0
        )
    }

    fun withdraw_for_internal<C>(
        caller_addr: address,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_withdraw<C>(), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_address));

        accrue_interest<C>(asset_storage_ref);
        collect_asset_fee<C>(pool_ref, liquidation_fee);

        let amount_to_transfer = amount - liquidation_fee;
        coin::deposit<C>(receiver_addr, coin::extract(&mut pool_ref.asset, amount_to_transfer));

        let amount_u128 = (amount as u128);
        let withdrawn_user_share_u128: u128;
        if (is_collateral_only) {
            withdrawn_user_share_u128 = math128::to_share_roundup(amount_u128, asset_storage_ref.total_conly_deposited_amount, asset_storage_ref.total_conly_deposited_share);
            asset_storage_ref.total_conly_deposited_amount = asset_storage_ref.total_conly_deposited_amount - amount_u128;
            asset_storage_ref.total_conly_deposited_share = asset_storage_ref.total_conly_deposited_share - withdrawn_user_share_u128;
        } else {
            withdrawn_user_share_u128 = math128::to_share_roundup(amount_u128, asset_storage_ref.total_normal_deposited_amount, asset_storage_ref.total_normal_deposited_amount);
            asset_storage_ref.total_normal_deposited_amount = asset_storage_ref.total_normal_deposited_amount - amount_u128;
            asset_storage_ref.total_normal_deposited_share = asset_storage_ref.total_normal_deposited_share - withdrawn_user_share_u128;
        };

        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).withdraw_event,
            WithdrawEvent {
                caller: caller_addr,
                receiver: receiver_addr,
                amount,
                is_collateral_only,
            },
        );

        (amount, (withdrawn_user_share_u128 as u64))
    }

    /// Borrows an asset or a shadow from the pool.
    public fun borrow_for<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
        _key: &AssetPoolKey,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        borrow_for_internal<C>(borrower_addr, receiver_addr, amount)
    }

    fun borrow_for_internal<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_borrow<C>(), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_address));

        accrue_interest<C>(asset_storage_ref);

        let fee = risk_factor::calculate_entry_fee(amount);
        let amount_with_fee = amount + fee;
        assert!((amount_with_fee as u128) <= liquidity_internal(pool_ref, asset_storage_ref), error::invalid_argument(EINSUFFICIENT_LIQUIDITY));

        collect_asset_fee<C>(pool_ref, fee);
        let borrowed = coin::extract(&mut pool_ref.asset, amount);
        coin::deposit<C>(receiver_addr, borrowed);

        let share_u128 = math128::to_share((amount_with_fee as u128), asset_storage_ref.total_borrowed_amount, asset_storage_ref.total_borrowed_share);
        asset_storage_ref.total_borrowed_amount = asset_storage_ref.total_borrowed_amount + (amount_with_fee as u128);
        asset_storage_ref.total_borrowed_share = asset_storage_ref.total_borrowed_share + share_u128;

        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).borrow_event,
            BorrowEvent {
                caller: borrower_addr,
                borrower: borrower_addr,
                receiver: receiver_addr,
                amount: amount_with_fee,
            },
        );

        (
            amount_with_fee, // TODO: only amount
            (share_u128 as u64)
        )
    }

    /// Repays an asset or a shadow for the borrowed position.
    public fun repay<C>(
        account: &signer,
        amount: u64,
        _key: &AssetPoolKey,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        repay_internal<C>(account, amount)
    }

    fun repay_internal<C>(
        account: &signer,
        amount: u64,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_repay<C>(), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_address));

        accrue_interest<C>(asset_storage_ref);

        let account_addr = signer::address_of(account);
        let share_u128 = math128::to_share_roundup((amount as u128), asset_storage_ref.total_borrowed_amount, asset_storage_ref.total_borrowed_share);
        asset_storage_ref.total_borrowed_amount = asset_storage_ref.total_borrowed_amount - (amount as u128);
        asset_storage_ref.total_borrowed_share = asset_storage_ref.total_borrowed_share - share_u128;
        let withdrawn = coin::withdraw<C>(account, amount);
        coin::merge(&mut pool_ref.asset, withdrawn);

        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).repay_event,
            RepayEvent {
                caller: account_addr,
                repay_target: account_addr,
                amount,
            },
        );

        (amount, (share_u128 as u64))
    }

    public fun withdraw_for_liquidation<C>(
        liquidator_addr: address,
        target_addr: address,
        withdrawing: u64,
        is_collateral_only: bool,
        _key: &AssetPoolKey,
    ) acquires Pool, Storage, PoolEventHandle {
        withdraw_for_liquidation_internal<C>(liquidator_addr, target_addr, withdrawing, is_collateral_only)
    }

    fun withdraw_for_liquidation_internal<C>(
        liquidator_addr: address,
        target_addr: address,
        withdrawing: u64,
        is_collateral_only: bool,
    ) acquires Pool, Storage, PoolEventHandle {
        let owner_address = permission::owner_address();
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_address));

        accrue_interest<C>(asset_storage_ref);
        let liquidation_fee = risk_factor::calculate_liquidation_fee(withdrawing);
        withdraw_for_internal<C>(liquidator_addr, liquidator_addr, withdrawing, is_collateral_only, liquidation_fee);

        event::emit_event<LiquidateEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).liquidate_event,
            LiquidateEvent {
                caller: liquidator_addr,
                target: target_addr,
            }
        );
    }

    public fun switch_collateral<C>(caller: address, amount: u64, to_collateral_only: bool, _key: &AssetPoolKey) acquires Pool, Storage, PoolEventHandle {
        switch_collateral_internal<C>(caller, amount, to_collateral_only);
    }

    fun switch_collateral_internal<C>(caller: address, amount: u64, to_collateral_only: bool) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_switch_collateral<C>(), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));
        let owner_address = permission::owner_address();
        let pool_ref = borrow_global<Pool<C>>(owner_address);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_address));

        let amount_u128 = (amount as u128);
        if (to_collateral_only) {
            assert!(amount_u128 <= liquidity_internal(pool_ref, asset_storage_ref), error::invalid_argument(EINSUFFICIENT_LIQUIDITY));
            asset_storage_ref.total_conly_deposited_amount = asset_storage_ref.total_conly_deposited_amount + amount_u128;
            asset_storage_ref.total_normal_deposited_amount = asset_storage_ref.total_normal_deposited_amount - amount_u128;
        } else {
            assert!(amount_u128 <= asset_storage_ref.total_conly_deposited_amount, error::invalid_argument(EINSUFFICIENT_CONLY_DEPOSITED));
            asset_storage_ref.total_normal_deposited_amount = asset_storage_ref.total_normal_deposited_amount + amount_u128;
            asset_storage_ref.total_conly_deposited_amount = asset_storage_ref.total_conly_deposited_amount - amount_u128;
        };
        event::emit_event<SwitchCollateralEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).switch_collateral_event,
            SwitchCollateralEvent {
                caller,
                amount,
                to_collateral_only,
            },
        );
    }

    public fun is_pool_initialized<C>(): bool {
        exists<Pool<C>>(permission::owner_address())
    }

    /// This function is called on every user action.
    fun accrue_interest<C>(asset_storage_ref: &mut AssetStorage) {
        let now = timestamp::now_microseconds();
        let key = key<C>();

        // This is the first time
        if (asset_storage_ref.last_updated == 0) {
            asset_storage_ref.last_updated = now;
            return
        };

        if (asset_storage_ref.last_updated == now) {
            return
        };

        let protocol_share_fee = risk_factor::share_fee();
        let rcomp = interest_rate::update_interest_rate(
            key,
            asset_storage_ref.total_normal_deposited_amount,
            asset_storage_ref.total_borrowed_amount,
            asset_storage_ref.last_updated,
            now,
        );
        let accrued_interest = asset_storage_ref.total_borrowed_amount * rcomp / interest_rate::precision();
        let protocol_share = accrued_interest * (protocol_share_fee as u128) / interest_rate::precision();
        let new_protocol_fees = asset_storage_ref.protocol_fees + (protocol_share as u64);

        let depositors_share = accrued_interest - protocol_share;
        asset_storage_ref.total_borrowed_amount = asset_storage_ref.total_borrowed_amount + accrued_interest;
        asset_storage_ref.total_normal_deposited_amount = asset_storage_ref.total_normal_deposited_amount + depositors_share;
        asset_storage_ref.protocol_fees = new_protocol_fees;
        asset_storage_ref.last_updated = now;
        asset_storage_ref.rcomp = rcomp;
    }

    fun collect_asset_fee<C>(pool_ref: &mut Pool<C>, fee: u64) {
        if (fee > 0) {
            let fee_extracted = coin::extract(&mut pool_ref.asset, fee);
            treasury::collect_fee<C>(fee_extracted);
        };
    }

    public fun harvest_protocol_fees<C>() acquires Pool, Storage{
        let owner_addr = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_addr);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_addr));
        let harvested_fee = (asset_storage_ref.protocol_fees - asset_storage_ref.harvested_protocol_fees as u128);
        if(harvested_fee == 0){
            return
        };
        let liquidity = liquidity_internal(pool_ref, asset_storage_ref);
        if(harvested_fee > liquidity){
            harvested_fee = liquidity;
        };
        asset_storage_ref.harvested_protocol_fees = asset_storage_ref.harvested_protocol_fees + (harvested_fee as u64);
        collect_asset_fee<C>(pool_ref, (harvested_fee as u64));
    }


    public fun protocol_fees<C>(): u64 acquires Storage {
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(permission::owner_address()));
        asset_storage_ref.protocol_fees
    }

    public fun harvested_protocol_fees<C>(): u64 acquires Storage {
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(permission::owner_address()));
        asset_storage_ref.harvested_protocol_fees
    }

    fun borrow_mut_asset_storage<C>(storage_ref: &mut Storage): &mut AssetStorage {
        borrow_mut_asset_storage_with(storage_ref, key<C>())
    }
    fun borrow_mut_asset_storage_with(storage_ref: &mut Storage, key: String): &mut AssetStorage {
        simple_map::borrow_mut<String, AssetStorage>(&mut storage_ref.assets, &key)
    }

    public fun liquidity<C>(): u128 acquires Pool, Storage {
        let owner_addr = permission::owner_address();
        let pool_ref = borrow_global<Pool<C>>(owner_addr);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_addr));
        liquidity_internal(pool_ref, asset_storage_ref)
    }
    fun liquidity_internal<C>(pool: &Pool<C>, asset_storage_ref: &AssetStorage): u128 {
        (coin::value(&pool.asset) as u128) - asset_storage_ref.total_conly_deposited_amount
    }

    public fun total_normal_deposited_amount<C>(): u128 acquires Storage {
        total_normal_deposited_amount_with(key<C>())
    }
    public fun total_normal_deposited_amount_with(key: String): u128 acquires Storage {
        let asset_storage_ref = borrow_mut_asset_storage_with(borrow_global_mut<Storage>(permission::owner_address()), key);
        asset_storage_ref.total_normal_deposited_amount
    }

    public fun total_normal_deposited_share<C>(): u128 acquires Storage {
        total_normal_deposited_share_with(key<C>())
    }
    public fun total_normal_deposited_share_with(key: String): u128 acquires Storage {
        let asset_storage_ref = borrow_mut_asset_storage_with(borrow_global_mut<Storage>(permission::owner_address()), key);
        asset_storage_ref.total_normal_deposited_share
    }

    public fun total_conly_deposited_amount<C>(): u128 acquires Storage {
        total_conly_deposited_amount_with(key<C>())
    }
    public fun total_conly_deposited_amount_with(key: String): u128 acquires Storage {
        let asset_storage_ref = borrow_mut_asset_storage_with(borrow_global_mut<Storage>(permission::owner_address()), key);
        asset_storage_ref.total_conly_deposited_amount
    }

    public fun total_conly_deposited_share<C>(): u128 acquires Storage {
        total_conly_deposited_share_with(key<C>())
    }
    public fun total_conly_deposited_share_with(key: String): u128 acquires Storage {
        let asset_storage_ref = borrow_mut_asset_storage_with(borrow_global_mut<Storage>(permission::owner_address()), key);
        asset_storage_ref.total_conly_deposited_share
    }

    public fun total_borrowed_amount<C>(): u128 acquires Storage {
        total_borrowed_amount_with(key<C>())
    }
    public fun total_borrowed_amount_with(key: String): u128 acquires Storage {
        let asset_storage_ref = borrow_mut_asset_storage_with(borrow_global_mut<Storage>(permission::owner_address()), key);
        asset_storage_ref.total_borrowed_amount
    }

    public fun total_borrowed_share<C>(): u128 acquires Storage {
        total_borrowed_share_with(key<C>())
    }
    public fun total_borrowed_share_with(key: String): u128 acquires Storage {
        let asset_storage_ref = borrow_mut_asset_storage_with(borrow_global_mut<Storage>(permission::owner_address()), key);
        asset_storage_ref.total_borrowed_share
    }

    public fun last_updated<C>(): u64 acquires Storage {
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(permission::owner_address()));
        asset_storage_ref.last_updated
    }

    // #[test_only]
    // use aptos_std::debug;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_trove::usdz::{USDZ};
    #[test_only]
    use leizd::dummy;
    #[test_only]
    use leizd::test_coin::{Self,USDC,USDT,WETH,UNI};
    #[test_only]
    use leizd::test_initializer;

    #[test(owner=@leizd)]
    public entry fun test_initialize(owner: &signer) {
        initialize(owner);
        assert!(exists<Storage>(signer::address_of(owner)), 0);
    }
    #[test(account=@0x111)]
    #[expected_failure(abort_code = 65537)]
    public entry fun test_initialize_with_not_owner(account: &signer) {
        initialize(account);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65538)]
    public entry fun test_initialize_twice(owner: &signer) {
        initialize(owner);
        initialize(owner);
    }
    #[test(owner=@leizd)]
    public entry fun test_init_pool(owner: &signer) acquires Pool, Storage {
        // Prerequisite
        let owner_address = signer::address_of(owner);
        account::create_account_for_test(owner_address);
        test_coin::init_weth(owner);
        test_initializer::initialize(owner);
        initialize(owner);
        
        init_pool<WETH>(owner);

        assert!(exists<Pool<WETH>>(owner_address), 0);
        let pool = borrow_global<Pool<WETH>>(owner_address);
        assert!(coin::value<WETH>(&pool.asset) == 0, 0);
        assert!(pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
        assert!(is_pool_initialized<WETH>(), 0);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65537)]
    public entry fun test_init_pool_before_initialized(owner: &signer) acquires Storage {
        // Prerequisite
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_weth(owner);
        test_initializer::initialize(owner);

        init_pool<WETH>(owner);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65538)]
    public entry fun test_init_pool_twice(owner: &signer) acquires Storage {
        // Prerequisite
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_weth(owner);
        test_initializer::initialize(owner);
        initialize(owner);

        init_pool<WETH>(owner);
        init_pool<WETH>(owner);
    }

    #[test(owner=@leizd)]
    public entry fun test_is_pool_initialized(owner: &signer) acquires Storage {
        // Prerequisite
        let owner_address = signer::address_of(owner);
        account::create_account_for_test(owner_address);
        test_initializer::initialize(owner);
        //// init coin & pool
        initialize(owner);
        test_coin::init_weth(owner);
        init_pool<WETH>(owner);
        test_coin::init_usdc(owner);
        init_pool<USDC>(owner);
        test_coin::init_usdt(owner);

        assert!(is_pool_initialized<WETH>(), 0);
        assert!(is_pool_initialized<USDC>(), 0);
        assert!(!is_pool_initialized<USDT>(), 0);
    }

    // for deposit
    #[test_only]
    fun setup_for_test_to_initialize_coins_and_pools(owner: &signer, aptos_framework: &signer) acquires Storage {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        test_initializer::initialize(owner);
        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);

        initialize(owner);
        init_pool<USDC>(owner);
        init_pool<USDT>(owner);
        init_pool<WETH>(owner);
        init_pool<UNI>(owner);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH>(account, account_addr, 800000, false);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 800000, 0);
        assert!(liquidity<WETH>() == 800000, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<DepositEvent>(&event_handle.deposit_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_with_same_as_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 1000000, false);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(total_normal_deposited_amount<WETH>() == 1000000, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_deposit_with_more_than_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 1000001, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_twice_sequentially(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        timestamp::update_global_time_for_test(1662125899730897);
        deposit_for_internal<WETH>(account, account_addr, 400000, false);
        timestamp::update_global_time_for_test(1662125899830897);
        deposit_for_internal<WETH>(account, account_addr, 400000, false);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 800000, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_by_two(owner: &signer, account1: &signer, account2: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);
        managed_coin::register<WETH>(account1);
        managed_coin::register<WETH>(account2);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        managed_coin::mint<WETH>(owner, account2_addr, 1000000);

        deposit_for_internal<WETH>(account1, account1_addr, 800000, false);
        deposit_for_internal<WETH>(account2, account2_addr, 200000, false);
        assert!(coin::balance<WETH>(account1_addr) == 200000, 0);
        assert!(coin::balance<WETH>(account2_addr) == 800000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 1000000, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65537)]
    public entry fun test_deposit_with_dummy_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        dummy::init_weth(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::register<dummy::WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        managed_coin::mint<dummy::WETH>(owner, account_addr, 1000000);

        deposit_for_internal<dummy::WETH>(account, account_addr, 800000, false);
    }

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH>(account, account_addr, 800000, true);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(liquidity<WETH>() == 0, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(total_conly_deposited_amount<WETH>() == 800000, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);
    }

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_with_all_patterns_over_time(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 10);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<WETH>(account, account_addr, 1, false);
        timestamp::update_global_time_for_test((initial_sec + 90) * 1000 * 1000); // + 90 sec
        deposit_for_internal<WETH>(account, account_addr, 2, true);

        assert!(liquidity<WETH>() == 1, 0);
        assert!(total_normal_deposited_amount<WETH>() == 1, 0);
        assert!(total_conly_deposited_amount<WETH>() == 2, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<DepositEvent>(&event_handle.deposit_event) == 2, 0);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        // test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH>(account, account_addr, 700000, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 600000, false, 0);

        assert!(coin::balance<WETH>(account_addr) == 900000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 100000, 0);
        assert!(liquidity<WETH>() == 100000, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_same_as_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 30, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 30, false, 0);

        assert!(coin::balance<WETH>(account_addr) == 100, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 50, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 51, false, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::register<USDZ>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 700000, true);
        withdraw_for_internal<WETH>(account_addr, account_addr, 600000, true, 0);

        assert!(coin::balance<WETH>(account_addr) == 900000, 0);
        assert!(liquidity<WETH>() == 0, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(total_conly_deposited_amount<WETH>() == 100000, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_all_patterns_over_time(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 20);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<WETH>(account, account_addr, 10, false);
        timestamp::update_global_time_for_test((initial_sec + 150) * 1000 * 1000); // + 150 sec
        deposit_for_internal<WETH>(account, account_addr, 10, true);

        timestamp::update_global_time_for_test((initial_sec + 300) * 1000 * 1000); // + 150 sec
        withdraw_for_internal<WETH>(account_addr, account_addr, 1, false, 0);
        timestamp::update_global_time_for_test((initial_sec + 450) * 1000 * 1000); // + 150 sec
        withdraw_for_internal<WETH>(account_addr, account_addr, 2, true, 0);

        assert!(coin::balance<WETH>(account_addr) == 3, 0);
        assert!(liquidity<WETH>() == 9, 0);
        assert!(total_normal_deposited_amount<WETH>() == 9, 0);
        assert!(total_conly_deposited_amount<WETH>() == 8, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 2, 0);
    }

    // for borrow
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_uni(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 1000000);

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 800000, false);

        // borrow UNI
        let (borrowed, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 100000);
        assert!(borrowed == 100500, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 100000, 0);
        assert!(total_normal_deposited_amount<UNI>() == 800000, 0);
        assert!(liquidity<UNI>() == 699500, 0);
        assert!(total_conly_deposited_amount<UNI>() == 0, 0);
        assert!(total_borrowed_amount<UNI>() == 100500, 0); // 100000 + 500

        // check about fee
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(treasury::balance<UNI>() == 500, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<BorrowEvent>(&event_handle.borrow_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_with_same_as_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 1000 + 5);

        // Prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        //// deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 1000 + 5, false);
        //// borrow UNI
        let (borrowed, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(borrowed == 1005, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 1000, 0);
        assert!(treasury::balance<UNI>() == 5, 0);
        assert!(pool_asset_value<UNI>(signer::address_of(owner)) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    fun test_borrow_with_more_than_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 100);

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        // borrow UNI
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 101);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_more_than_once_sequentially(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 10000 + 5 * 10);

        // Prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        //// deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 10000 + 5 * 10, false);
        //// borrow UNI
        let (borrowed, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(borrowed == 1005, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 1000, 0);
        assert!(total_borrowed_amount<UNI>() == 1000 + 5 * 1, 0);
        let (borrowed, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 2000);
        assert!(borrowed == 2010, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 3000, 0);
        assert!(total_borrowed_amount<UNI>() == 3000 + 5 * 3, 0);
        let (borrowed, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 3000);
        assert!(borrowed == 3015, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 6000, 0);
        assert!(total_borrowed_amount<UNI>() == 6000 + 5 * 6, 0);
        let (borrowed, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 4000);
        assert!(borrowed == 4020, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 10000, 0);
        assert!(total_borrowed_amount<UNI>() == 10000 + 5 * 10, 0);
    }
    // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // fun test_borrow_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<UNI>(depositor);
    //     managed_coin::register<UNI>(borrower);
    //     managed_coin::mint<UNI>(owner, depositor_addr, 100 + 4);

    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     // deposit UNI
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
    //     deposit_for_internal<UNI>(depositor, depositor_addr, 100 + 4, false);
    //     // borrow UNI
    //     timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
    //     borrow_for_internal<UNI>(borrower_addr, borrower_addr, 10);
    //     assert!(coin::balance<UNI>(borrower_addr) == 10, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 500) * 1000 * 1000); // + 250 sec
    //     borrow_for_internal<UNI>(borrower_addr, borrower_addr, 20);
    //     assert!(coin::balance<UNI>(borrower_addr) == 30, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 750) * 1000 * 1000); // + 250 sec
    //     borrow_for_internal<UNI>(borrower_addr, borrower_addr, 30);
    //     assert!(coin::balance<UNI>(borrower_addr) == 60, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 1000) * 1000 * 1000); // + 250 sec
    //     borrow_for_internal<UNI>(borrower_addr, borrower_addr, 40);
    //     assert!(coin::balance<UNI>(borrower_addr) == 100, 0);
    // }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    fun test_borrow_to_not_borrow_collateral_only(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 150);

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        deposit_for_internal<UNI>(depositor, depositor_addr, 50, true);
        // borrow UNI
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 120);
    }

    // for repay
    #[test_only]
    fun pool_asset_value<C>(addr: address): u64 acquires Pool {
        coin::value(&borrow_global<Pool<C>>(addr).asset)
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        assert!(pool_asset_value<UNI>(owner_address) == 1005, 0);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(pool_asset_value<UNI>(owner_address) == 0, 0);
        repay_internal<UNI>(borrower, 900);
        assert!(pool_asset_value<UNI>(owner_address) == 900, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 100, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_with_same_as_total_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        repay_internal<UNI>(borrower, 1000);
        assert!(pool_asset_value<UNI>(owner_address) == 1000, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_repay_with_more_than_total_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        repay_internal<UNI>(borrower, 1001);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_more_than_once_sequentially(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        repay_internal<UNI>(borrower, 100);
        assert!(pool_asset_value<UNI>(owner_address) == 100, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 900, 0);
        repay_internal<UNI>(borrower, 200);
        assert!(pool_asset_value<UNI>(owner_address) == 300, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 700, 0);
        repay_internal<UNI>(borrower, 300);
        assert!(pool_asset_value<UNI>(owner_address) == 600, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 400, 0);
        repay_internal<UNI>(borrower, 400);
        assert!(pool_asset_value<UNI>(owner_address) == 1000, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 4, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 1005);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        timestamp::update_global_time_for_test((initial_sec + 80) * 1000 * 1000); // + 80 sec
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);

        timestamp::update_global_time_for_test((initial_sec + 160) * 1000 * 1000); // + 80 sec
        repay_internal<UNI>(borrower, 100);
        assert!(pool_asset_value<UNI>(owner_address) == 100, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 900, 0);
        timestamp::update_global_time_for_test((initial_sec + 240) * 1000 * 1000); // + 80 sec
        repay_internal<UNI>(borrower, 200);
        assert!(pool_asset_value<UNI>(owner_address) == 300, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 700, 0);
        timestamp::update_global_time_for_test((initial_sec + 320) * 1000 * 1000); // + 80 sec
        repay_internal<UNI>(borrower, 300);
        assert!(pool_asset_value<UNI>(owner_address) == 600, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 400, 0);
        // timestamp::update_global_time_for_test((initial_sec + 400) * 1000 * 1000); // + 80 sec
        // let repaid_amount = repay_internal<UNI>(borrower, 400); // TODO: fail here because of ARITHMETIC_ERROR in accrue_interest (Cannot cast u128 to u64)
        // assert!(repaid_amount == 400, 0);
        // assert!(pool_asset_value<UNI>(owner_address) == 1000, 0);
        // assert!(coin::balance<UNI>(borrower_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 3, 0);
    }

    // for liquidation
    #[test(owner=@leizd,depositor=@0x111,liquidator=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_for_liquidation(owner: &signer, depositor: &signer, liquidator: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let liquidator_addr = signer::address_of(liquidator);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(liquidator_addr);
        managed_coin::register<WETH>(depositor);
        managed_coin::register<WETH>(liquidator);
        managed_coin::mint<WETH>(owner, depositor_addr, 1001);

        deposit_for_internal<WETH>(depositor, depositor_addr, 1001, false);
        assert!(pool_asset_value<WETH>(owner_address) == 1001, 0);
        assert!(total_normal_deposited_amount<WETH>() == 1001, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(coin::balance<WETH>(depositor_addr) == 0, 0);
        assert!(coin::balance<WETH>(liquidator_addr) == 0, 0);

        withdraw_for_liquidation_internal<WETH>(liquidator_addr, liquidator_addr, 1001, false);
        assert!(pool_asset_value<WETH>(owner_address) == 0, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(coin::balance<WETH>(depositor_addr) == 0, 0);
        assert!(coin::balance<WETH>(liquidator_addr) == 995, 0);
        assert!(treasury::balance<WETH>() == 6, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<LiquidateEvent>(&event_handle.liquidate_event) == 1, 0);
    }

    // for switch_collateral
    #[test(owner=@leizd, account=@0x111, aptos_framework=@aptos_framework)]
    public entry fun test_switch_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let owner_addr = signer::address_of(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000);

        deposit_for_internal<WETH>(account, account_addr, 1000, false);
        assert!(liquidity<WETH>() == 1000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 1000, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);

        switch_collateral_internal<WETH>(account_addr, 800, true);
        assert!(liquidity<WETH>() == 200, 0);
        assert!(total_normal_deposited_amount<WETH>() == 200, 0);
        assert!(total_conly_deposited_amount<WETH>() == 800, 0);
        assert!(event::counter<SwitchCollateralEvent>(&borrow_global<PoolEventHandle<WETH>>(owner_addr).switch_collateral_event) == 1, 0);

        switch_collateral_internal<WETH>(account_addr, 400, false);
        assert!(liquidity<WETH>() == 600, 0);
        assert!(total_normal_deposited_amount<WETH>() == 600, 0);
        assert!(total_conly_deposited_amount<WETH>() == 400, 0);
        assert!(event::counter<SwitchCollateralEvent>(&borrow_global<PoolEventHandle<WETH>>(owner_addr).switch_collateral_event) == 2, 0);
    }
    #[test(owner=@leizd, account=@0x111, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_switch_collateral_when_amount_is_zero(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000);

        deposit_for_internal<WETH>(account, account_addr, 1000, false);
        switch_collateral_internal<WETH>(account_addr, 0, true);
    }
    #[test(owner=@leizd, account=@0x111, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    public entry fun test_switch_collateral_to_collateral_only_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000);

        deposit_for_internal<WETH>(account, account_addr, 1000, false);
        switch_collateral_internal<WETH>(account_addr, 1001, true);
    }
    #[test(owner=@leizd, account=@0x111, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65549)]
    public entry fun test_switch_collateral_to_normal_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000);

        deposit_for_internal<WETH>(account, account_addr, 1000, true);
        switch_collateral_internal<WETH>(account_addr, 1001, false);
    }

    // for common validations
    //// `amount` arg
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_deposit_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        deposit_for_internal<WETH>(owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_withdraw_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal<WETH>(owner_address, owner_address, 0, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_borrow_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_address = signer::address_of(owner);
        borrow_for_internal<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_repay_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        repay_internal<WETH>(owner, 0);
    }
    //// control pool status
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196613)]
    public entry fun test_cannot_deposit_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_deposit_status_for_test<WETH>(false);
        deposit_for_internal<WETH>(owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196613)]
    public entry fun test_cannot_withdraw_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_withdraw_status_for_test<WETH>(false);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal<WETH>(owner_address, owner_address, 0, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196613)]
    public entry fun test_cannot_borrow_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_borrow_status_for_test<WETH>(false);
        let owner_address = signer::address_of(owner);
        borrow_for_internal<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196613)]
    public entry fun test_cannot_repay_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_repay_status_for_test<WETH>(false);
        repay_internal<WETH>(owner, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_harvest_protocol_fees(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(risk_factor::share_fee() == risk_factor::default_share_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 3000000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 3000000, false);
        assert!(pool_asset_value<UNI>(owner_address) == 3000000, 0);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
        assert!(pool_asset_value<UNI>(owner_address) == 2998995, 0);
        repay_internal<UNI>(borrower, 1000);
        assert!(pool_asset_value<UNI>(owner_address) == 2999995, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
        let total_protocol_fees = protocol_fees<UNI>();
        assert!(total_protocol_fees > 0, 0);
        assert!(harvested_protocol_fees<UNI>() == 0, 0);
        let treasury_balance = treasury::balance<UNI>();
        harvest_protocol_fees<UNI>();
        assert!(protocol_fees<UNI>() == total_protocol_fees, 0);
        assert!(harvested_protocol_fees<UNI>() == total_protocol_fees, 0);
        assert!(treasury::balance<UNI>() == treasury_balance + total_protocol_fees, 0);
        assert!(pool_asset_value<UNI>(owner_address) == 2999995 - total_protocol_fees, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_harvest_protocol_fees_more_than_liquidity(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(risk_factor::share_fee() == risk_factor::default_share_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 300000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 300000, false);
        assert!(pool_asset_value<UNI>(owner_address) == 300000, 0);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
        assert!(pool_asset_value<UNI>(owner_address) == 298995, 0);
        repay_internal<UNI>(borrower, 1000);
        assert!(pool_asset_value<UNI>(owner_address) == 299995, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
        let total_protocol_fees = protocol_fees<UNI>();
        let liquidity = liquidity<UNI>();
        assert!(liquidity > 0, 0);
        assert!((total_protocol_fees as u128) > liquidity, 0);
        assert!(harvested_protocol_fees<UNI>() == 0, 0);
        let treasury_balance = treasury::balance<UNI>();
        harvest_protocol_fees<UNI>();
        assert!(protocol_fees<UNI>() == total_protocol_fees, 0);
        assert!((harvested_protocol_fees<UNI>() as u128) == liquidity, 0);
        assert!((treasury::balance<UNI>() as u128) == (treasury_balance as u128) + liquidity, 0);
        assert!((pool_asset_value<UNI>(owner_address) as u128) == 299995 - liquidity, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_harvest_protocol_fees_at_zero(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(risk_factor::share_fee() == risk_factor::default_share_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 3000000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 3000000, false);
        assert!(pool_asset_value<UNI>(owner_address) == 3000000, 0);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
        assert!(pool_asset_value<UNI>(owner_address) == 2998995, 0);
        repay_internal<UNI>(borrower, 1000);
        assert!(pool_asset_value<UNI>(owner_address) == 2999995, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
        let total_protocol_fees = protocol_fees<UNI>();
        assert!(total_protocol_fees > 0, 0);
        assert!(harvested_protocol_fees<UNI>() == 0, 0);
        let treasury_balance = treasury::balance<UNI>();
        harvest_protocol_fees<UNI>();
        assert!(protocol_fees<UNI>() == total_protocol_fees, 0);
        assert!(harvested_protocol_fees<UNI>() == total_protocol_fees, 0);
        assert!(treasury::balance<UNI>() == treasury_balance + total_protocol_fees, 0);
        assert!(pool_asset_value<UNI>(owner_address) == 2999995 - total_protocol_fees, 0);
        // harvest again
        treasury_balance = treasury::balance<UNI>();
        let pool_balance = pool_asset_value<UNI>(owner_address);
        harvest_protocol_fees<UNI>();
        assert!(protocol_fees<UNI>() - harvested_protocol_fees<UNI>() == 0, 0);
        assert!(treasury::balance<UNI>() == treasury_balance, 0);
        assert!(pool_asset_value<UNI>(owner_address) == pool_balance, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    }
}
