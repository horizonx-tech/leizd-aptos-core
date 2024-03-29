module leizd::asset_pool {

    use std::error;
    use std::signer;
    use std::vector;
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::simple_map;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use leizd_aptos_lib::constant;
    use leizd_aptos_lib::math128;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::permission;
    use leizd_aptos_common::pool_status::{Self, AssetManagerKey as PoolStatusKey};
    use leizd_aptos_treasury::treasury::{Self, AssetManagerKey as TreasuryKey};
    use leizd_aptos_central_liquidity_pool::central_liquidity_pool::{Self, AssetManagerKey as CentralLiquidityPoolKey};
    use leizd_aptos_logic::risk_factor::{Self, AssetManagerKey as RiskFactorKey};
    use leizd::interest_rate::{Self, AssetManagerKey as InterestRateKey};

    friend leizd::pool_manager;

    //// error_code
    const ENOT_INITIALIZED: u64 = 1;
    const EIS_ALREADY_EXISTED: u64 = 2;
    const EIS_NOT_EXISTED: u64 = 3;
    const EDEX_DOES_NOT_HAVE_LIQUIDITY: u64 = 4;
    const ENOT_AVAILABLE_STATUS: u64 = 5;
    const EAMOUNT_ARG_IS_ZERO: u64 = 11;
    const EINSUFFICIENT_LIQUIDITY: u64 = 12;
    const EINSUFFICIENT_CONLY_DEPOSITED: u64 = 13;
    const EEXCEED_COIN_IN_POOL: u64 = 14;

    //// resources
    /// access control
    struct OperatorKey has store, drop {}
    struct AssetManagerKeys has key {
        treasury: TreasuryKey,
        risk_factor: RiskFactorKey,
        interest_rate: InterestRateKey,
        central_liquidity_pool: CentralLiquidityPoolKey,
        pool_status: PoolStatusKey
    }

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
        protocol_fees: u128,
        harvested_protocol_fees: u128,
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

    ////////////////////////////////////////////////////
    /// Initialize
    ////////////////////////////////////////////////////
    public entry fun initialize(owner: &signer): OperatorKey {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);

        initialize_module(owner);
        connect_with_mods_to_manage_assets(owner);
        let key = publish_operator_key(owner);
        key
    }
    fun initialize_module(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);

        assert!(!exists<Storage>(owner_addr), error::invalid_argument(EIS_ALREADY_EXISTED));
        move_to(owner, Storage {
            assets: simple_map::create<String, AssetStorage>(),
        });
    }
    fun connect_with_mods_to_manage_assets(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);

        move_to(owner, AssetManagerKeys {
            treasury: treasury::publish_asset_manager_key(owner),
            risk_factor: risk_factor::publish_asset_manager_key(owner),
            interest_rate: interest_rate::publish_asset_manager_key(owner),
            central_liquidity_pool: central_liquidity_pool::publish_asset_manager_key(owner),
            pool_status: pool_status::publish_asset_manager_key(owner)
        });
    }
    fun publish_operator_key(owner: &signer): OperatorKey {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);

        OperatorKey {}
    }
    //// for assets
    /// Initializes a pool with the coin the owner specifies.
    /// The caller is only owner and creates not only a pool but also other resources
    /// such as a treasury for the coin, an interest rate model, and coins of collaterals and debts.
    public(friend) fun init_pool<C>(account: &signer) acquires Storage, AssetManagerKeys {
        init_pool_internal<C>(account);
    }

    fun init_pool_internal<C>(account: &signer) acquires Storage, AssetManagerKeys {
        let owner_addr = permission::owner_address();
        assert!(exists<Storage>(owner_addr), error::invalid_argument(ENOT_INITIALIZED));
        assert!(!is_pool_initialized<C>(), error::invalid_argument(EIS_ALREADY_EXISTED));

        let keys = borrow_global<AssetManagerKeys>(owner_addr);
        treasury::add_coin<C>(account, &keys.treasury);
        risk_factor::initialize_for_asset<C>(account, &keys.risk_factor);
        interest_rate::initialize_for_asset<C>(account, &keys.interest_rate);
        central_liquidity_pool::initialize_for_asset<C>(account, &keys.central_liquidity_pool);
        pool_status::initialize_for_asset<C>(account, &keys.pool_status);

        move_to(account, Pool<C> {
            asset: coin::zero<C>()
        });
        let storage_ref = borrow_global_mut<Storage>(owner_addr);
        simple_map::add<String, AssetStorage>(&mut storage_ref.assets, key<C>(), default_asset_storage());
        move_to(account, PoolEventHandle<C> {
            deposit_event: account::new_event_handle<DepositEvent>(account),
            withdraw_event: account::new_event_handle<WithdrawEvent>(account),
            borrow_event: account::new_event_handle<BorrowEvent>(account),
            repay_event: account::new_event_handle<RepayEvent>(account),
            liquidate_event: account::new_event_handle<LiquidateEvent>(account),
            switch_collateral_event: account::new_event_handle<SwitchCollateralEvent>(account),
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

    ////////////////////////////////////////////////////
    /// Deposit
    ////////////////////////////////////////////////////
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
        _key: &OperatorKey
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

        accrue_interest(key<C>(), asset_storage_ref);

        let user_share_u128: u128;
        let withdrawn = coin::withdraw<C>(account, amount);
        assert!(coin::value(&withdrawn) <= constant::u64_max() - coin::value(&pool_ref.asset), error::invalid_argument(EEXCEED_COIN_IN_POOL));
        coin::merge(&mut pool_ref.asset, withdrawn);
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

    ////////////////////////////////////////////////////
    /// Withdraw
    ////////////////////////////////////////////////////
    public fun withdraw_for<C>(
        caller_addr: address,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool,
        _key: &OperatorKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        withdraw_for_internal<C>(
            caller_addr,
            receiver_addr,
            amount,
            is_collateral_only,
            false,
            0
        )
    }

    public fun withdraw_for_by_share<C>(
        caller_addr: address,
        receiver_addr: address,
        share: u64,
        is_collateral_only: bool,
        _key: &OperatorKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        withdraw_for_internal<C>(
            caller_addr,
            receiver_addr,
            share,
            is_collateral_only,
            true,
            0
        )
    }

    fun withdraw_for_internal<C>(
        caller_addr: address,
        receiver_addr: address,
        value: u64,
        is_collateral_only: bool,
        is_share: bool,
        liquidation_fee: u64,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_withdraw<C>(), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(value > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_address));

        accrue_interest(key<C>(), asset_storage_ref);
        collect_fee<C>(pool_ref, liquidation_fee);

        let amount_u128: u128;
        let share_u128: u128;
        if (is_share) {
            share_u128 = (value as u128);
            if (is_collateral_only) {
                amount_u128 = math128::to_amount(share_u128, asset_storage_ref.total_conly_deposited_amount, asset_storage_ref.total_conly_deposited_share);
            } else {
                amount_u128 = math128::to_amount(share_u128, asset_storage_ref.total_normal_deposited_amount, asset_storage_ref.total_normal_deposited_share);
            };
        } else {
            amount_u128 = (value as u128);
            if (is_collateral_only) {
                share_u128 = math128::to_share_roundup(amount_u128, asset_storage_ref.total_conly_deposited_amount, asset_storage_ref.total_conly_deposited_share);
            } else {
                share_u128 = math128::to_share_roundup(amount_u128, asset_storage_ref.total_normal_deposited_amount, asset_storage_ref.total_normal_deposited_share);
            };
        };

        let amount_to_transfer = (amount_u128 as u64) - liquidation_fee;
        coin::deposit<C>(receiver_addr, coin::extract(&mut pool_ref.asset, amount_to_transfer));
        if (is_collateral_only) {
            asset_storage_ref.total_conly_deposited_amount = math128::sub(asset_storage_ref.total_conly_deposited_amount, amount_u128);
            asset_storage_ref.total_conly_deposited_share = math128::sub(asset_storage_ref.total_conly_deposited_share, share_u128);
        } else {
            asset_storage_ref.total_normal_deposited_amount = math128::sub(asset_storage_ref.total_normal_deposited_amount, amount_u128);
            asset_storage_ref.total_normal_deposited_share = math128::sub(asset_storage_ref.total_normal_deposited_share, share_u128);
        };

        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).withdraw_event,
            WithdrawEvent {
                caller: caller_addr,
                receiver: receiver_addr,
                amount: (amount_u128 as u64),
                is_collateral_only,
            },
        );

        ((amount_u128 as u64), (share_u128 as u64))
    }

    ////////////////////////////////////////////////////
    /// Borrow
    ////////////////////////////////////////////////////
    public fun borrow_for<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
        _key: &OperatorKey,
    ): (u64, u64, u64) acquires Pool, Storage, PoolEventHandle {
        borrow_for_internal<C>(borrower_addr, receiver_addr, amount)
    }

    fun borrow_for_internal<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
    ): (
        u64, // amount
        u64, // fee
        u64, // share
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_borrow<C>(), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_address));

        accrue_interest(key<C>(), asset_storage_ref);

        let fee = risk_factor::calculate_entry_fee(amount);
        let amount_with_fee = amount + fee; // FIXME: possibility that exceed u64 max
        assert!(amount_with_fee <= liquidity_internal(pool_ref, asset_storage_ref), error::invalid_argument(EINSUFFICIENT_LIQUIDITY));

        collect_fee<C>(pool_ref, fee);
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
                amount,
            },
        );

        (
            amount,
            fee,
            (share_u128 as u64)
        )
    }

    ////////////////////////////////////////////////////
    /// Repay
    ////////////////////////////////////////////////////
    public fun repay<C>(
        account: &signer,
        amount: u64,
        _key: &OperatorKey,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        repay_internal<C>(account, amount, false)
    }

    public fun repay_by_share<C>(
        account: &signer,
        share: u64,
        _key: &OperatorKey,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        repay_internal<C>(account, share, true)
    }

    fun repay_internal<C>(
        account: &signer,
        value: u64,
        is_share: bool
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_repay<C>(), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(value > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_address));

        accrue_interest(key<C>(), asset_storage_ref);

        let amount_u128: u128;
        let share_u128: u128;
        if (is_share) {
            share_u128 = (value as u128);
            amount_u128 = math128::to_amount(share_u128, asset_storage_ref.total_borrowed_amount, asset_storage_ref.total_borrowed_share);
        } else {
            amount_u128 = (value as u128);
            share_u128 = math128::to_share_roundup(amount_u128, asset_storage_ref.total_borrowed_amount, asset_storage_ref.total_borrowed_share);
        };

        asset_storage_ref.total_borrowed_amount = math128::sub(asset_storage_ref.total_borrowed_amount, amount_u128);
        asset_storage_ref.total_borrowed_share = asset_storage_ref.total_borrowed_share - share_u128;
        let withdrawn = coin::withdraw<C>(account, (amount_u128 as u64));
        coin::merge(&mut pool_ref.asset, withdrawn);

        let account_addr = signer::address_of(account);
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).repay_event,
            RepayEvent {
                caller: account_addr,
                repay_target: account_addr,
                amount: (amount_u128 as u64),
            },
        );

        ((amount_u128 as u64), (share_u128 as u64))
    }

    public fun withdraw_for_liquidation<C>(
        liquidator_addr: address,
        target_addr: address,
        withdrawing: u64,
        is_collateral_only: bool,
        _key: &OperatorKey,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        withdraw_for_liquidation_internal<C>(liquidator_addr, target_addr, withdrawing, is_collateral_only)
    }

    fun withdraw_for_liquidation_internal<C>(
        liquidator_addr: address,
        target_addr: address,
        withdrawing: u64,
        is_collateral_only: bool,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        let owner_address = permission::owner_address();
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_address));

        accrue_interest(key<C>(), asset_storage_ref);
        let liquidation_fee = risk_factor::calculate_liquidation_fee(withdrawing);
        let (amount, share) = withdraw_for_internal<C>(liquidator_addr, liquidator_addr, withdrawing, is_collateral_only, false, liquidation_fee);

        event::emit_event<LiquidateEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).liquidate_event,
            LiquidateEvent {
                caller: liquidator_addr,
                target: target_addr,
            }
        );

        (amount, share)
    }

    ////////////////////////////////////////////////////
    /// Switch Collateral
    ////////////////////////////////////////////////////
    public fun switch_collateral<C>(caller: address, share: u64, to_collateral_only: bool, _key: &OperatorKey): (u64, u64, u64) acquires Storage, PoolEventHandle {
        switch_collateral_internal<C>(caller, share, to_collateral_only)
    }

    fun switch_collateral_internal<C>(caller: address, share: u64, to_collateral_only: bool): (
        u64, // amount
        u64, // share for from
        u64, // share for to
    ) acquires Storage, PoolEventHandle {
        assert!(pool_status::can_switch_collateral<C>(), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(share > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));
        let owner_address = permission::owner_address();
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_address));

        accrue_interest(key<C>(), asset_storage_ref);

        let from_share_u128 = (share as u128);
        let amount_u128: u128;
        let to_share_u128: u128;
        if (to_collateral_only) {
            assert!(from_share_u128 <= asset_storage_ref.total_normal_deposited_share, error::invalid_argument(EINSUFFICIENT_LIQUIDITY));

            amount_u128 = math128::to_amount(from_share_u128, asset_storage_ref.total_normal_deposited_amount, asset_storage_ref.total_normal_deposited_share);
            to_share_u128 = math128::to_share(amount_u128, asset_storage_ref.total_conly_deposited_amount, asset_storage_ref.total_conly_deposited_share);

            asset_storage_ref.total_normal_deposited_amount = asset_storage_ref.total_normal_deposited_amount - amount_u128;
            asset_storage_ref.total_normal_deposited_share = asset_storage_ref.total_normal_deposited_share - from_share_u128;
            asset_storage_ref.total_conly_deposited_amount = asset_storage_ref.total_conly_deposited_amount + amount_u128;
            asset_storage_ref.total_conly_deposited_share = asset_storage_ref.total_conly_deposited_share + to_share_u128;
        } else {
            assert!(from_share_u128 <= asset_storage_ref.total_conly_deposited_share, error::invalid_argument(EINSUFFICIENT_CONLY_DEPOSITED));

            amount_u128 = math128::to_amount(from_share_u128, asset_storage_ref.total_conly_deposited_amount, asset_storage_ref.total_conly_deposited_share);
            to_share_u128 = math128::to_share(amount_u128, asset_storage_ref.total_normal_deposited_amount, asset_storage_ref.total_normal_deposited_share);

            asset_storage_ref.total_conly_deposited_amount = asset_storage_ref.total_conly_deposited_amount - amount_u128;
            asset_storage_ref.total_conly_deposited_share = asset_storage_ref.total_conly_deposited_share - from_share_u128;
            asset_storage_ref.total_normal_deposited_amount = asset_storage_ref.total_normal_deposited_amount + amount_u128;
            asset_storage_ref.total_normal_deposited_share = asset_storage_ref.total_normal_deposited_share + to_share_u128;
        };

        event::emit_event<SwitchCollateralEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).switch_collateral_event,
            SwitchCollateralEvent {
                caller,
                amount: (amount_u128 as u64),
                to_collateral_only,
            },
        );

        ((amount_u128 as u64), (from_share_u128 as u64), (to_share_u128 as u64))
    }

    ////////////////////////////////////////////////////
    /// Update status
    ////////////////////////////////////////////////////
    public fun exec_accrue_interest<C>(
        _key: &OperatorKey
    ) acquires Storage {
        exec_accrue_interest_internal(key<C>());
    }
    public fun exec_accrue_interest_with(
        key: String,
        _key: &OperatorKey
    ) acquires Storage {
        exec_accrue_interest_internal(key);
    }
    fun exec_accrue_interest_internal(
        key: String,
    ) acquires Storage {
        let owner_address = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_address);
        accrue_interest(key, borrow_mut_asset_storage_with(storage_ref, key));
    }
    public fun exec_accrue_interest_for_selected(
        keys: vector<String>,
        _key: &OperatorKey
    ) acquires Storage {
        exec_accrue_interest_for_selected_internal(keys);
    }
    fun exec_accrue_interest_for_selected_internal(keys: vector<String>) acquires Storage {
        let owner_address = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_address);

        let i = vector::length<String>(&keys);
        while (i > 0) {
            let key = *vector::borrow<String>(&keys, i - 1);
            accrue_interest(key, borrow_mut_asset_storage_with(storage_ref, key));
            i = i - 1;
        };
    }

    /// This function is called on every user action.
    fun accrue_interest(key: String, asset_storage_ref: &mut AssetStorage) {
        let now = timestamp::now_microseconds();

        // This is the first time
        if (asset_storage_ref.last_updated == 0) {
            asset_storage_ref.last_updated = now;
            return
        };

        if (asset_storage_ref.last_updated == now) {
            return
        };

        let rcomp = interest_rate::compound_interest_rate(
            key,
            asset_storage_ref.total_normal_deposited_amount,
            asset_storage_ref.total_borrowed_amount,
            asset_storage_ref.last_updated,
            now,
        );
        save_calculated_values_by_rcomp(asset_storage_ref, rcomp, risk_factor::share_fee());
        asset_storage_ref.last_updated = now;
        asset_storage_ref.rcomp = rcomp;
    }
    fun save_calculated_values_by_rcomp(asset_storage_ref: &mut AssetStorage, rcomp: u128, share_fee: u64) {
        let accrued_interest = asset_storage_ref.total_borrowed_amount * rcomp / interest_rate::precision();
        let protocol_share = accrued_interest * (share_fee as u128) / risk_factor::precision_u128();
        let new_protocol_fees = asset_storage_ref.protocol_fees + protocol_share;

        let depositors_share = accrued_interest - protocol_share;
        asset_storage_ref.total_borrowed_amount = asset_storage_ref.total_borrowed_amount + accrued_interest;
        asset_storage_ref.total_normal_deposited_amount = asset_storage_ref.total_normal_deposited_amount + depositors_share;
        asset_storage_ref.protocol_fees = new_protocol_fees;
    }

    fun collect_fee<C>(pool_ref: &mut Pool<C>, fee: u64) {
        if (fee == 0) return;
        let fee_extracted = coin::extract(&mut pool_ref.asset, fee);
        treasury::collect_fee<C>(fee_extracted);
    }

    public entry fun harvest_protocol_fees<C>() acquires Pool, Storage {
        let owner_addr = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_addr);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_addr));
        let unharvested_fee = asset_storage_ref.protocol_fees - asset_storage_ref.harvested_protocol_fees;
        if (unharvested_fee == 0) {
            return
        };
        let harvested_fee: u64;
        let liquidity = liquidity_internal(pool_ref, asset_storage_ref);
        if (unharvested_fee > (liquidity as u128)) {
            harvested_fee = liquidity;
        } else {
            harvested_fee = (unharvested_fee as u64);
        };
        asset_storage_ref.harvested_protocol_fees = asset_storage_ref.harvested_protocol_fees + (harvested_fee as u128);
        collect_fee<C>(pool_ref, harvested_fee);
    }

    //// Convert
    public fun normal_deposited_share_to_amount(key: String, share: u64): u128 acquires Storage {
        let total_amount = total_normal_deposited_amount_with(key);
        let total_share = total_normal_deposited_share_with(key);
        if (total_amount > 0 || total_share > 0) {
            math128::to_amount((share as u128), total_amount, total_share)
        } else {
            0
        }
    }
    public fun conly_deposited_share_to_amount(key: String, share: u64): u128 acquires Storage {
        let total_amount = total_conly_deposited_amount_with(key);
        let total_share = total_conly_deposited_share_with(key);
        if (total_amount > 0 || total_share > 0) {
            math128::to_amount((share as u128), total_amount, total_share)
        } else {
            0
        }
    }
    public fun borrowed_share_to_amount(key: String, share: u64): u128 acquires Storage {
        let total_amount = total_borrowed_amount_with(key);
        let total_share = total_borrowed_share_with(key);
        if (total_amount > 0 || total_share > 0) {
            math128::to_amount((share as u128), total_amount, total_share)
        } else {
            0
        }
    }

    ////// View functions
    fun borrow_mut_asset_storage<C>(storage_ref: &mut Storage): &mut AssetStorage {
        borrow_mut_asset_storage_with(storage_ref, key<C>())
    }
    fun borrow_mut_asset_storage_with(storage_ref: &mut Storage, key: String): &mut AssetStorage {
        simple_map::borrow_mut<String, AssetStorage>(&mut storage_ref.assets, &key)
    }

    public fun is_pool_initialized<C>(): bool {
        exists<Pool<C>>(permission::owner_address())
    }

    public fun liquidity<C>(): u64 acquires Pool, Storage {
        let owner_addr = permission::owner_address();
        let pool_ref = borrow_global<Pool<C>>(owner_addr);
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_addr));
        liquidity_internal(pool_ref, asset_storage_ref)
    }
    fun liquidity_internal<C>(pool: &Pool<C>, asset_storage_ref: &AssetStorage): u64 {
        let coin = coin::value(&pool.asset);
        if ((coin as u128) > asset_storage_ref.total_conly_deposited_amount) {
            let liquidity = (coin as u128) - asset_storage_ref.total_conly_deposited_amount;
            (liquidity as u64)
        } else {
            0
        }
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

    public fun protocol_fees<C>(): u128 acquires Storage {
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(permission::owner_address()));
        asset_storage_ref.protocol_fees
    }

    public fun harvested_protocol_fees<C>(): u128 acquires Storage {
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(permission::owner_address()));
        asset_storage_ref.harvested_protocol_fees
    }

    #[test_only]
    friend leizd::shadow_pool;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_lib::math64;
    #[test_only]
    use leizd_aptos_common::test_coin::{Self,USDC,USDT,WETH,UNI,CoinDec10};
    #[test_only]
    use leizd_aptos_trove::usdz::{USDZ};
    #[test_only]
    use leizd::dummy;
    #[test_only]
    use leizd::test_initializer;

    #[test_only]
    public fun init_pool_for_test<C>(owner: &signer) acquires Storage, AssetManagerKeys {
        init_pool_internal<C>(owner);
    }
    #[test(owner=@leizd)]
    fun test_initialize(owner: &signer) {
        initialize(owner);
        assert!(exists<Storage>(signer::address_of(owner)), 0);
    }
    #[test(account=@0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_initialize_with_not_owner(account: &signer) {
        initialize(account);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65538)]
    fun test_initialize_twice(owner: &signer) {
        initialize(owner);
        initialize(owner);
    }
    #[test(owner=@leizd)]
    fun test_init_pool(owner: &signer) acquires Pool, Storage, AssetManagerKeys {
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
    fun test_init_pool_before_initialized(owner: &signer) acquires Storage, AssetManagerKeys {
        // Prerequisite
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_weth(owner);
        test_initializer::initialize(owner);

        init_pool<WETH>(owner);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65538)]
    fun test_init_pool_twice(owner: &signer) acquires Storage, AssetManagerKeys {
        // Prerequisite
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_weth(owner);
        test_initializer::initialize(owner);
        initialize(owner);

        init_pool<WETH>(owner);
        init_pool<WETH>(owner);
    }

    #[test(owner=@leizd)]
    fun test_is_pool_initialized(owner: &signer) acquires Storage, AssetManagerKeys {
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
    fun setup_for_test_to_initialize_coins_and_pools(owner: &signer, aptos_framework: &signer) acquires Storage, AssetManagerKeys {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        test_initializer::initialize(owner);
        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        test_coin::init_coin_dec_10(owner);

        initialize(owner);
        init_pool<USDC>(owner);
        init_pool<USDT>(owner);
        init_pool<WETH>(owner);
        init_pool<UNI>(owner);
        init_pool<CoinDec10>(owner);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_deposit_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        let (amount, _) = deposit_for_internal<WETH>(account, account_addr, 800000, false);
        assert!(amount == 800000, 0);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 800000, 0);
        assert!(liquidity<WETH>() == 800000, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<DepositEvent>(&event_handle.deposit_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_deposit_with_same_as_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        let (amount, _) = deposit_for_internal<WETH>(account, account_addr, 1000000, false);
        assert!(amount == 1000000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(total_normal_deposited_amount<WETH>() == 1000000, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    fun test_deposit_with_more_than_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 1000001, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_deposit_weth_twice_sequentially(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        timestamp::update_global_time_for_test(1662125899730897);
        let (amount, _) = deposit_for_internal<WETH>(account, account_addr, 400000, false);
        assert!(amount == 400000, 0);
        timestamp::update_global_time_for_test(1662125899830897);
        let (amount, _) = deposit_for_internal<WETH>(account, account_addr, 400000, false);
        assert!(amount == 400000, 0);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 800000, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    fun test_deposit_weth_by_two(owner: &signer, account1: &signer, account2: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
    #[expected_failure(abort_code = 65538)]
    fun test_deposit_with_dummy_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
    fun test_deposit_weth_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        let (amount, _) = deposit_for_internal<WETH>(account, account_addr, 800000, true);
        assert!(amount == 800000, 0);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(liquidity<WETH>() == 0, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(total_conly_deposited_amount<WETH>() == 800000, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);
    }

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_deposit_with_all_patterns_over_time(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_deposit_with_u64_max(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        let max = constant::u64_max();
        managed_coin::mint<WETH>(owner, account_addr, max);
        assert!(coin::balance<WETH>(account_addr) == max, 0);

        let (amount, _) = deposit_for_internal<WETH>(account, account_addr, max, false);
        assert!(amount == max, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(total_normal_deposited_amount<WETH>() == (max as u128), 0);
        assert!(liquidity<WETH>() == max, 0);
    }

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_deposit_to_check_share(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_addr = permission::owner_address();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 50000);

        // execute
        let (amount, share) = deposit_for_internal<WETH>(account, account_addr, 1000, false);
        assert!(amount == 1000, 0);
        assert!(share == 1000, 0);

        //// update total_xxxx (instead of interest by accrue_interest)
        let total_normal_deposited_amount = &mut borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).total_normal_deposited_amount;
        *total_normal_deposited_amount = *total_normal_deposited_amount + 1000;

        let (amount, share) = deposit_for_internal<WETH>(account, account_addr, 500, false);
        assert!(amount == 500, 0);
        assert!(share == 250, 0); 

        //// update total_xxxx (instead of interest by accrue_interest)
        let total_normal_deposited_amount = &mut borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).total_normal_deposited_amount;
        *total_normal_deposited_amount = *total_normal_deposited_amount + 2500;

        let (amount, share) = deposit_for_internal<WETH>(account, account_addr, 20000, false);
        assert!(amount == 20000, 0);
        assert!(share == 5000, 0);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        // test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH>(account, account_addr, 700000, false);
        let (amount, _) = withdraw_for_internal<WETH>(account_addr, account_addr, 600000, false, false, 0);
        assert!(amount == 600000, 0);

        assert!(coin::balance<WETH>(account_addr) == 900000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 100000, 0);
        assert!(liquidity<WETH>() == 100000, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_with_same_as_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 30, false);
        let (amount, _) = withdraw_for_internal<WETH>(account_addr, account_addr, 30, false, false, 0);
        assert!(amount == 30, 0);

        assert!(coin::balance<WETH>(account_addr) == 100, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 50, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 51, false, false, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::register<USDZ>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 700000, true);
        let (amount, _) = withdraw_for_internal<WETH>(account_addr, account_addr, 600000, true, false, 0);
        assert!(amount == 600000, 0);

        assert!(coin::balance<WETH>(account_addr) == 900000, 0);
        assert!(liquidity<WETH>() == 0, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(total_conly_deposited_amount<WETH>() == 100000, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_with_all_patterns_over_time(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
        withdraw_for_internal<WETH>(account_addr, account_addr, 1, false, false, 0);
        timestamp::update_global_time_for_test((initial_sec + 450) * 1000 * 1000); // + 150 sec
        withdraw_for_internal<WETH>(account_addr, account_addr, 2, true, false, 0);

        assert!(coin::balance<WETH>(account_addr) == 3, 0);
        assert!(liquidity<WETH>() == 9, 0);
        assert!(total_normal_deposited_amount<WETH>() == 9, 0);
        assert!(total_conly_deposited_amount<WETH>() == 8, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 2, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_with_u64_max(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        // test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        let max = constant::u64_max();
        managed_coin::mint<WETH>(owner, account_addr, max);

        deposit_for_internal<WETH>(account, account_addr, max, false);
        let (amount, _) = withdraw_for_internal<WETH>(account_addr, account_addr, max, false, false, 0);
        assert!(amount == max, 0);

        assert!(coin::balance<WETH>(account_addr) == max, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(liquidity<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_by_share_with_u64_max(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        // test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_addr = signer::address_of(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        let max = constant::u64_max();
        managed_coin::mint<WETH>(owner, account_addr, max);

        // execute
        //// amount value = share value
        deposit_for_internal<WETH>(account, account_addr, max, false);
        let (amount, share) = withdraw_for_internal<WETH>(account_addr, account_addr, max, false, true, 0);
        assert!(amount == max, 0);
        assert!(share == max, 0);
        assert!(coin::balance<WETH>(account_addr) == max, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);

        //// amount value > share value
        deposit_for_internal<WETH>(account, account_addr, max / 5, false);

        ////// update total_xxxx (instead of interest by accrue_interest)
        let total_normal_deposited_amount = &mut borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).total_normal_deposited_amount;
        *total_normal_deposited_amount = *total_normal_deposited_amount * 5;
        coin::merge(&mut borrow_global_mut<Pool<WETH>>(owner_addr).asset, coin::withdraw<WETH>(account, max / 5 * 4));
        assert!(total_normal_deposited_amount<WETH>() == (max as u128), 0);
        assert!(total_normal_deposited_share<WETH>() == (max / 5 as u128), 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);

        let (amount, share) = withdraw_for_internal<WETH>(account_addr, account_addr, max / 5, false, true, 0);
        assert!(amount == max, 0);
        assert!(share == max / 5, 0);
        assert!(coin::balance<WETH>(account_addr) == max, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_to_check_share(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_addr = permission::owner_address();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 50000);

        // execute
        let (amount, share) = deposit_for_internal<WETH>(account, account_addr, 10000, false);
        assert!(amount == 10000, 0);
        assert!(share == 10000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 10000, 0);
        assert!(total_normal_deposited_share<WETH>() == 10000, 0);

        //// update total_xxxx (instead of interest by accrue_interest)
        let total_normal_deposited_amount = &mut borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).total_normal_deposited_amount;
        *total_normal_deposited_amount = *total_normal_deposited_amount - 9000;
        assert!(total_normal_deposited_amount<WETH>() == 1000, 0);
        assert!(total_normal_deposited_share<WETH>() == 10000, 0);

        let (amount, share) = withdraw_for_internal<WETH>(account_addr, account_addr, 500, false, false, 0);
        assert!(amount == 500, 0);
        assert!(share == 5000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 500, 0);
        assert!(total_normal_deposited_share<WETH>() == 5000, 0);

        //// update total_xxxx (instead of interest by accrue_interest)
        let total_normal_deposited_amount = &mut borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).total_normal_deposited_amount;
        *total_normal_deposited_amount = *total_normal_deposited_amount + 1500;
        assert!(total_normal_deposited_amount<WETH>() == 2000, 0);
        assert!(total_normal_deposited_share<WETH>() == 5000, 0);

        let (amount, share) = withdraw_for_internal<WETH>(account_addr, account_addr, 2000, false, false, 0);
        assert!(amount == 2000, 0);
        assert!(share == 5000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(total_normal_deposited_share<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,withdrawer=@0x222,aptos_framework=@aptos_framework)]
    fun test_withdraw_by_share(owner: &signer, depositor: &signer, withdrawer: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let owner_addr = permission::owner_address();
        let depositor_addr = signer::address_of(depositor);
        account::create_account_for_test(depositor_addr);
        managed_coin::register<WETH>(depositor);
        managed_coin::mint<WETH>(owner, depositor_addr, 50000);
        let withdrawer_addr = signer::address_of(withdrawer);
        account::create_account_for_test(withdrawer_addr);
        managed_coin::register<WETH>(withdrawer);

        deposit_for_internal<WETH>(depositor, depositor_addr, 10000, false);
        let total_normal_deposited_amount = &mut borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).total_normal_deposited_amount;
        *total_normal_deposited_amount = *total_normal_deposited_amount - 9000;
        assert!(total_normal_deposited_amount<WETH>() == 1000, 0);
        assert!(total_normal_deposited_share<WETH>() == 10000, 0);

        // by share
        let (amount, share) = withdraw_for_internal<WETH>(withdrawer_addr, withdrawer_addr, 2000, false, true, 0);
        assert!(amount == 200, 0);
        assert!(share == 2000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 800, 0);
        assert!(total_normal_deposited_share<WETH>() == 8000, 0);
        // by amount
        let (amount, share) = withdraw_for_internal<WETH>(withdrawer_addr, withdrawer_addr, 500, false, false, 0);
        assert!(amount == 500, 0);
        assert!(share == 5000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 300, 0);
        assert!(total_normal_deposited_share<WETH>() == 3000, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,withdrawer=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code=65539)]
    fun test_withdraw_by_share_with_more_than_deposited(owner: &signer, depositor: &signer, withdrawer: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let owner_addr = permission::owner_address();
        let depositor_addr = signer::address_of(depositor);
        account::create_account_for_test(depositor_addr);
        managed_coin::register<WETH>(depositor);
        managed_coin::mint<WETH>(owner, depositor_addr, 50000);
        let withdrawer_addr = signer::address_of(withdrawer);
        account::create_account_for_test(withdrawer_addr);
        managed_coin::register<WETH>(withdrawer);

        deposit_for_internal<WETH>(depositor, depositor_addr, 10000, false);
        let total_normal_deposited_amount = &mut borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).total_normal_deposited_amount;
        *total_normal_deposited_amount = *total_normal_deposited_amount - 9000;
        assert!(total_normal_deposited_amount<WETH>() == 1000, 0);
        assert!(total_normal_deposited_share<WETH>() == 10000, 0);

        // by share
        withdraw_for_internal<WETH>(withdrawer_addr, withdrawer_addr, 10001, false, true, 0);
    }

    // for borrow
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_uni(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
        let (borrowed, imposed_fee, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 100000);
        assert!(borrowed == 100000, 0);
        assert!(imposed_fee == 500, 0);
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
    fun test_borrow_with_same_as_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
        let (borrowed, imposed_fee, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(borrowed == 1000, 0);
        assert!(imposed_fee == 5, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 1000, 0);
        assert!(treasury::balance<UNI>() == 5, 0);
        assert!(pool_value<UNI>() == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    fun test_borrow_with_more_than_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
    fun test_borrow_more_than_once_sequentially(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
        let (borrowed, imposed_fee, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(borrowed == 1000, 0);
        assert!(imposed_fee == 5, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 1000, 0);
        assert!(total_borrowed_amount<UNI>() == 1000 + 5 * 1, 0);
        let (borrowed, imposed_fee, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 2000);
        assert!(borrowed == 2000, 0);
        assert!(imposed_fee == 10, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 3000, 0);
        assert!(total_borrowed_amount<UNI>() == 3000 + 5 * 3, 0);
        let (borrowed, imposed_fee, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 3000);
        assert!(borrowed == 3000, 0);
        assert!(imposed_fee == 15, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 6000, 0);
        assert!(total_borrowed_amount<UNI>() == 6000 + 5 * 6, 0);
        let (borrowed, imposed_fee, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 4000);
        assert!(borrowed == 4000, 0);
        assert!(imposed_fee == 20, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 10000, 0);
        assert!(total_borrowed_amount<UNI>() == 10000 + 5 * 10, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle, AssetManagerKeys {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 10000 + 5 * 10);

        let initial_sec = 1648738800; // 20220401T00:00:00
        // deposit UNI
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 10000 + 5 * 10, false);
        // borrow UNI
        timestamp::update_global_time_for_test((initial_sec + 2628000) * 1000 * 1000); // + 2628000 sec (1 month)
        let (borrowed, imposed_fee, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(borrowed == 1000, 0);
        assert!(imposed_fee == 5, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 1000, 0);
        assert!(total_borrowed_amount<UNI>() == 1000 + 5 * 1, 0);
        timestamp::update_global_time_for_test((initial_sec + 2628000*2) * 1000 * 1000); // + 2628000 sec (1 month)
        let (borrowed, imposed_fee, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 2000);
        assert!(borrowed == 2000, 0);
        assert!(imposed_fee == 10, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 3000, 0);
        assert!(total_borrowed_amount<UNI>() == 3000 + 5 * 3 + 1, 0); // +1: interest rate
        timestamp::update_global_time_for_test((initial_sec + 2628000*3) * 1000 * 1000); // + 2628000 sec (1 month)
        let (borrowed, imposed_fee, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 3000);
        assert!(borrowed == 3000, 0);
        assert!(imposed_fee == 15, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 6000, 0);
        assert!(total_borrowed_amount<UNI>() == 6000 + 5 * 6 + 12, 0); // +12: interest rate 
        timestamp::update_global_time_for_test((initial_sec + 2628000*4) * 1000 * 1000); // + 2628000 sec (1 month)
        let (borrowed, imposed_fee, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 4000);
        assert!(borrowed == 4000, 0);
        assert!(imposed_fee == 20, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 10000, 0);
        assert!(total_borrowed_amount<UNI>() == 10000 + 5 * 10 + 51, 0); // +51: interest rate
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    fun test_borrow_to_not_borrow_collateral_only(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_with_u64_max(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        let max = constant::u64_max();
        managed_coin::mint<UNI>(owner, depositor_addr, max);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, max, false);

        // borrow UNI
        let (borrowed, imposed_fee, _) = borrow_for_internal<UNI>(borrower_addr, borrower_addr, max);
        assert!(borrowed == max, 0);
        assert!(imposed_fee == 0, 0);
        assert!(coin::balance<UNI>(borrower_addr) == max, 0);
        assert!(total_normal_deposited_amount<UNI>() == (max as u128), 0);
        assert!(liquidity<UNI>() == 0, 0);
        assert!(total_conly_deposited_amount<UNI>() == 0, 0);
        assert!(total_borrowed_amount<UNI>() == (max as u128), 0);

        // check about fee
        assert!(risk_factor::entry_fee() == 0, 0);
        assert!(treasury::balance<UNI>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<BorrowEvent>(&event_handle.borrow_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_borrow_to_check_share(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_addr = permission::owner_address();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 500000);

        // execute
        deposit_for_internal<WETH>(account, account_addr, 500000, false);
        assert!(total_normal_deposited_amount<WETH>() == 500000, 0);
        assert!(total_normal_deposited_share<WETH>() == 500000, 0);

        let (amount, imposed_fee, share) = borrow_for_internal<WETH>(account_addr, account_addr, 100000);
        assert!(amount == 100000, 0);
        assert!(imposed_fee == 500, 0);
        assert!(share == 100000 + 500, 0);
        assert!(total_borrowed_amount<WETH>() == 100500, 0);
        assert!(total_borrowed_share<WETH>() == 100500, 0);

        //// update total_xxxx (instead of interest by accrue_interest)
        let total_borrowed_amount = &mut borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).total_borrowed_amount;
        *total_borrowed_amount = *total_borrowed_amount + 100500;
        assert!(total_borrowed_amount<WETH>() == 201000, 0);
        assert!(total_borrowed_share<WETH>() == 100500, 0);

        let (amount, imposed_fee, share) = borrow_for_internal<WETH>(account_addr, account_addr, 50000);
        assert!(amount == 50000, 0);
        assert!(imposed_fee == 250, 0);
        assert!(share == 25125, 0);
        assert!(total_borrowed_amount<WETH>() == 250000 + 1250, 0);
        assert!(total_borrowed_share<WETH>() == 125000 + 625, 0);
    }

    // for repay
    #[test_only]
    fun pool_value<C>(): u64 acquires Pool {
        coin::value(&borrow_global<Pool<C>>(permission::owner_address()).asset)
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
        assert!(pool_value<(UNI)>() == 1005, 0);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(pool_value<(UNI)>() == 0, 0);
        repay_internal<UNI>(borrower, 900, false);
        assert!(pool_value<(UNI)>() == 900, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 100, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_with_same_as_total_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
        repay_internal<UNI>(borrower, 1000, false);
        assert!(pool_value<(UNI)>() == 1000, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    fun test_repay_with_more_than_total_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
        repay_internal<UNI>(borrower, 1001, false);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_more_than_once_sequentially(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
        repay_internal<UNI>(borrower, 100, false);
        assert!(pool_value<(UNI)>() == 100, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 900, 0);
        repay_internal<UNI>(borrower, 200, false);
        assert!(pool_value<(UNI)>() == 300, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 700, 0);
        repay_internal<UNI>(borrower, 300, false);
        assert!(pool_value<(UNI)>() == 600, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 400, 0);
        repay_internal<UNI>(borrower, 400, false);
        assert!(pool_value<(UNI)>() == 1000, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 4, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        timestamp::update_global_time_for_test((initial_sec + 80) * 1000 * 1000); // + 80 sec
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);

        timestamp::update_global_time_for_test((initial_sec + 160) * 1000 * 1000); // + 80 sec
        repay_internal<UNI>(borrower, 100, false);
        assert!(pool_value<(UNI)>() == 100, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 900, 0);
        timestamp::update_global_time_for_test((initial_sec + 240) * 1000 * 1000); // + 80 sec
        repay_internal<UNI>(borrower, 200, false);
        assert!(pool_value<(UNI)>() == 300, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 700, 0);
        timestamp::update_global_time_for_test((initial_sec + 320) * 1000 * 1000); // + 80 sec
        repay_internal<UNI>(borrower, 300, false);
        assert!(pool_value<(UNI)>() == 600, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 400, 0);
        timestamp::update_global_time_for_test((initial_sec + 400) * 1000 * 1000); // + 80 sec
        let (repaid_amount, _) = repay_internal<UNI>(borrower, 400, false);
        assert!(repaid_amount == 400, 0);
        assert!(pool_value<(UNI)>() == 1000, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 4, 0);
    }

    #[test_only]
    fun prepare_to_test_repay_by_share(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        assert!(risk_factor::entry_fee() == 0, 0);
        //// add liquidity
        let dec6 = math64::pow_10(6);
        managed_coin::mint<UNI>(owner, depositor_addr, 100000 * dec6);
        deposit_for_internal<UNI>(depositor, depositor_addr, 100000 * dec6, false);

    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_by_share__over_1_amount_per_1_share(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        prepare_to_test_repay_by_share(owner, depositor, borrower, aptos_framework);
        let owner_addr = signer::address_of(owner);
        let borrower_addr = signer::address_of(borrower);
        let dec6 = math64::pow_10(6);

        // execute
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 100000 * dec6);
        assert!(total_borrowed_amount<UNI>() == (100000 * dec6 as u128), 0);
        assert!(total_borrowed_share<UNI>() == (100000 * dec6 as u128), 0);

        //// update total_xxxx (instead of interest by accrue_interest)
        let total_borrowed_amount = &mut borrow_mut_asset_storage<UNI>(borrow_global_mut<Storage>(owner_addr)).total_borrowed_amount;
        *total_borrowed_amount = *total_borrowed_amount + (400000 * dec6 as u128);
        assert!(total_borrowed_amount<UNI>() == (500000 * dec6 as u128), 0);
        assert!(total_borrowed_share<UNI>() == (100000 * dec6 as u128), 0);

        managed_coin::mint<UNI>(owner, borrower_addr, 100000 * dec6);
        let (amount, share) = repay_internal<UNI>(borrower, 25000 * dec6, true);
        assert!(amount == 125000 * dec6, 0);
        assert!(share == 25000 * dec6, 0);
        assert!(total_borrowed_amount<UNI>() == (375000 * dec6 as u128), 0);
        assert!(total_borrowed_share<UNI>() == (75000 * dec6 as u128), 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_by_share__under_1_amount_per_1_share(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        prepare_to_test_repay_by_share(owner, depositor, borrower, aptos_framework);
        let owner_addr = signer::address_of(owner);
        let borrower_addr = signer::address_of(borrower);
        let dec6 = math64::pow_10(6);

        // execute
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 100000 * dec6);
        assert!(total_borrowed_amount<UNI>() == (100000 * dec6 as u128), 0);
        assert!(total_borrowed_share<UNI>() == (100000 * dec6 as u128), 0);

        //// update total_xxxx (instead of interest by accrue_interest)
        let total_borrowed_amount = &mut borrow_mut_asset_storage<UNI>(borrow_global_mut<Storage>(owner_addr)).total_borrowed_amount;
        *total_borrowed_amount = *total_borrowed_amount - (60000 * dec6 as u128);
        assert!(total_borrowed_amount<UNI>() == (40000 * dec6 as u128), 0);
        assert!(total_borrowed_share<UNI>() == (100000 * dec6 as u128), 0);

        let (amount, share) = repay_internal<UNI>(borrower, 20000 * dec6, true);
        assert!(amount == 8000 * dec6, 0);
        assert!(share == 20000 * dec6, 0);
        assert!(total_borrowed_amount<UNI>() == (32000 * dec6 as u128), 0);
        assert!(total_borrowed_share<UNI>() == (80000 * dec6 as u128), 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_with_u64_max(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        assert!(risk_factor::entry_fee() == 0, 0);
        //// add liquidity
        let max = constant::u64_max();
        managed_coin::mint<UNI>(owner, depositor_addr, max);
        deposit_for_internal<UNI>(depositor, depositor_addr, max, false);

        // execute
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, max);
        assert!(pool_value<(UNI)>() == 0, 0);
        assert!(coin::balance<UNI>(borrower_addr) == max, 0);
        assert!(total_borrowed_amount<UNI>() == (max as u128), 0);
        let (amount, _) = repay_internal<UNI>(borrower, max, false);
        assert!(amount == max, 0);
        assert!(pool_value<(UNI)>() == max, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
        assert!(total_borrowed_amount<UNI>() == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_by_share_with_u64_max(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        assert!(risk_factor::entry_fee() == 0, 0);
        //// add liquidity
        let max = constant::u64_max();
        managed_coin::mint<UNI>(owner, depositor_addr, max);
        deposit_for_internal<UNI>(depositor, depositor_addr, max, false);

        // execute
        //// amount value = share value
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, max);
        let (amount, share) = repay_internal<UNI>(borrower, max, true);
        assert!(amount == max, 0);
        assert!(share == max, 0);
        assert!(pool_value<(UNI)>() == max, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
        assert!(total_borrowed_amount<UNI>() == 0, 0);

        //// amount value > share value
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, max / 5);

        ////// update total_xxxx (instead of interest by accrue_interest)
        let total_borrowed_amount = &mut borrow_mut_asset_storage<UNI>(borrow_global_mut<Storage>(owner_addr)).total_borrowed_amount;
        *total_borrowed_amount = *total_borrowed_amount * 5;
        coin::deposit(borrower_addr, coin::extract(&mut borrow_global_mut<Pool<UNI>>(owner_addr).asset, max / 5 * 4));
        assert!(total_borrowed_amount<UNI>() == (max as u128), 0);
        assert!(total_borrowed_share<UNI>() == (max / 5 as u128), 0);
        assert!(coin::balance<UNI>(borrower_addr) == max, 0);

        let (amount, share) = repay_internal<UNI>(borrower, max / 5, true);
        assert!(amount == max, 0);
        assert!(share == max / 5, 0);
        assert!(pool_value<(UNI)>() == max, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
        assert!(total_borrowed_amount<UNI>() == 0, 0);
    }

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_repay_to_check_share(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_addr = permission::owner_address();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        // execute
        deposit_for_internal<WETH>(account, account_addr, 500000, false);
        assert!(total_normal_deposited_amount<WETH>() == 500000, 0);
        assert!(total_normal_deposited_share<WETH>() == 500000, 0);

        let (amount, imposed_fee, share) = borrow_for_internal<WETH>(account_addr, account_addr, 100000);
        assert!(amount == 100000, 0);
        assert!(imposed_fee == 500, 0);
        assert!(share == 100500, 0);
        assert!(total_borrowed_amount<WETH>() == 100500, 0);
        assert!(total_borrowed_share<WETH>() == 100500, 0);

        let (amount, share) = repay_internal<WETH>(account, 80500, false);
        assert!(amount == 80500, 0);
        assert!(share == 80500, 0);
        assert!(total_borrowed_amount<WETH>() == 20000, 0);
        assert!(total_borrowed_share<WETH>() == 20000, 0);

        //// update total_xxxx (instead of interest by accrue_interest)
        let total_borrowed_amount = &mut borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).total_borrowed_amount;
        *total_borrowed_amount = *total_borrowed_amount - 10000;
        assert!(total_borrowed_amount<WETH>() == 10000, 0);
        assert!(total_borrowed_share<WETH>() == 20000, 0);

        let (amount, share) = repay_internal<WETH>(account, 7500, false);
        assert!(amount == 7500, 0);
        assert!(share == 15000, 0);
        assert!(total_borrowed_amount<WETH>() == 2500, 0);
        assert!(total_borrowed_share<WETH>() == 5000, 0);

        //// update total_xxxx (instead of interest by accrue_interest)
        let total_borrowed_amount = &mut borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).total_borrowed_amount;
        *total_borrowed_amount = *total_borrowed_amount + 397500;
        assert!(total_borrowed_amount<WETH>() == 400000, 0);
        assert!(total_borrowed_share<WETH>() == 5000, 0);

        let (amount, share) = repay_internal<WETH>(account, 320000, false);
        assert!(amount == 320000, 0);
        assert!(share == 4000, 0);
        assert!(total_borrowed_amount<WETH>() == 80000, 0);
        assert!(total_borrowed_share<WETH>() == 1000, 0);

        let (amount, share) = repay_internal<WETH>(account, 80000, false);
        assert!(amount == 80000, 0);
        assert!(share == 1000, 0);
        assert!(total_borrowed_amount<WETH>() == 0, 0);
        assert!(total_borrowed_share<WETH>() == 0, 0);
    }

    // for liquidation
    #[test(owner=@leizd,depositor=@0x111,liquidator=@0x222,aptos_framework=@aptos_framework)]
    fun test_withdraw_for_liquidation(owner: &signer, depositor: &signer, liquidator: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let liquidator_addr = signer::address_of(liquidator);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(liquidator_addr);
        managed_coin::register<WETH>(depositor);
        managed_coin::register<WETH>(liquidator);
        managed_coin::mint<WETH>(owner, depositor_addr, 1001);

        deposit_for_internal<WETH>(depositor, depositor_addr, 1001, false);
        assert!(pool_value<(WETH)>() == 1001, 0);
        assert!(total_normal_deposited_amount<WETH>() == 1001, 0);
        assert!(total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(coin::balance<WETH>(depositor_addr) == 0, 0);
        assert!(coin::balance<WETH>(liquidator_addr) == 0, 0);

        let (amount, _) = withdraw_for_liquidation_internal<WETH>(liquidator_addr, liquidator_addr, 1001, false);
        assert!(amount == 1001, 0);
        assert!(pool_value<(WETH)>() == 0, 0);
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
    fun test_switch_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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

        // to check share
        let total_normal_deposited_amount = &mut borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).total_normal_deposited_amount;
        *total_normal_deposited_amount = *total_normal_deposited_amount + 2400;
        assert!(total_normal_deposited_amount<WETH>() == 3000, 0);
        assert!(total_normal_deposited_share<WETH>() == 600, 0);
        let (amount, from_share, to_share) = switch_collateral_internal<WETH>(account_addr, 100, true);
        assert!(amount == 500, 0);
        assert!(from_share == 100, 0);
        assert!(to_share == 500, 0);
        assert!(total_normal_deposited_amount<WETH>() == 2500, 0);
        assert!(total_normal_deposited_share<WETH>() == 500, 0);
        assert!(total_conly_deposited_amount<WETH>() == 900, 0);
        assert!(total_conly_deposited_share<WETH>() == 900, 0);
        let (amount, from_share, to_share) = switch_collateral_internal<WETH>(account_addr, 500, false);
        assert!(amount == 500, 0);
        assert!(from_share == 500, 0);
        assert!(to_share == 100, 0);
        assert!(total_normal_deposited_amount<WETH>() == 3000, 0);
        assert!(total_normal_deposited_share<WETH>() == 600, 0);
        assert!(total_conly_deposited_amount<WETH>() == 400, 0);
        assert!(total_conly_deposited_share<WETH>() == 400, 0);
    }
    #[test(owner=@leizd, account=@0x111, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    fun test_switch_collateral_when_amount_is_zero(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
    fun test_switch_collateral_to_collateral_only_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
    fun test_switch_collateral_to_normal_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
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
    fun test_cannot_deposit_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        deposit_for_internal<WETH>(owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    fun test_cannot_withdraw_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal<WETH>(owner_address, owner_address, 0, false, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    fun test_cannot_borrow_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_address = signer::address_of(owner);
        borrow_for_internal<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    fun test_cannot_repay_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        repay_internal<WETH>(owner, 0, false);
    }
    //// control pool status
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196613)]
    fun test_cannot_deposit_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_deposit_status_for_test<WETH>(false);
        deposit_for_internal<WETH>(owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196613)]
    fun test_cannot_withdraw_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_withdraw_status_for_test<WETH>(false);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal<WETH>(owner_address, owner_address, 0, false, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196613)]
    fun test_cannot_borrow_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_borrow_status_for_test<WETH>(false);
        let owner_address = signer::address_of(owner);
        borrow_for_internal<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196613)]
    fun test_cannot_repay_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_repay_status_for_test<WETH>(false);
        repay_internal<WETH>(owner, 0, false);
    }

    // for harvest_protocol_fees
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    fun test_harvest_protocol_fees_when_liquidity_is_greater_than_not_harvested(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_addr = signer::address_of(owner);
        let dec6 = math64::pow_10(6);

        // prerequisite
        coin::merge(
            &mut borrow_global_mut<Pool<USDC>>(owner_addr).asset,
            test_coin::mint_and_withdraw<USDC>(owner, 50000 * dec6)
        );
        let storage_ref = borrow_mut_asset_storage<USDC>(borrow_global_mut<Storage>(owner_addr));
        storage_ref.total_conly_deposited_amount = 20000 * (dec6 as u128);
        storage_ref.protocol_fees = 40000 * (dec6 as u128);
        storage_ref.harvested_protocol_fees = 5000 * (dec6 as u128);

        assert!(treasury::balance<USDC>() == 0, 0);
        assert!(pool_value<(USDC)>() == 50000 * dec6, 0);

        // execute
        harvest_protocol_fees<USDC>();
        assert!(treasury::balance<USDC>() == 30000 * dec6, 0);
        assert!(pool_value<(USDC)>() == 20000 * dec6, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    fun test_harvest_protocol_fees_when_liquidity_is_less_than_not_harvested(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_addr = signer::address_of(owner);
        let dec6 = math64::pow_10(6);

        // prerequisite
        coin::merge(
            &mut borrow_global_mut<Pool<USDC>>(owner_addr).asset,
            test_coin::mint_and_withdraw<USDC>(owner, 30000 * dec6)
        );
        let storage_ref = borrow_mut_asset_storage<USDC>(borrow_global_mut<Storage>(owner_addr));
        storage_ref.total_conly_deposited_amount = 20000 * (dec6 as u128);
        storage_ref.protocol_fees = 40000 * (dec6 as u128);
        storage_ref.harvested_protocol_fees = 5000 * (dec6 as u128);

        assert!(treasury::balance<USDC>() == 0, 0);
        assert!(pool_value<(USDC)>() == 30000 * dec6, 0);

        // execute
        harvest_protocol_fees<USDC>();
        assert!(treasury::balance<USDC>() == 10000 * dec6, 0);
        assert!(pool_value<(USDC)>() == 20000 * dec6, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    fun test_harvest_protocol_fees_when_not_harvested_is_greater_than_u64_max(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_addr = signer::address_of(owner);
        let max = constant::u64_max();

        // prerequisite
        coin::merge(
            &mut borrow_global_mut<Pool<USDC>>(owner_addr).asset,
            test_coin::mint_and_withdraw<USDC>(owner, max)
        );
        let storage_ref = borrow_mut_asset_storage<USDC>(borrow_global_mut<Storage>(owner_addr));
        storage_ref.protocol_fees = (max as u128) * 5;
        storage_ref.harvested_protocol_fees = (max as u128);

        assert!(treasury::balance<USDZ>() == 0, 0);
        assert!(pool_value<(USDC)>() == max, 0);

        // execute
        harvest_protocol_fees<USDC>();
        assert!(treasury::balance<USDC>() == max, 0);
        assert!(pool_value<(USDC)>() == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_harvest_protocol_fees(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        assert!(pool_value<(UNI)>() == 3000000, 0);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000000);
        assert!(pool_value<(UNI)>() == 1995000, 0);
        timestamp::update_global_time_for_test((initial_sec + 604800) * 1000 * 1000); // + 1 Week
        repay_internal<UNI>(borrower, 1000000, false);
        assert!(pool_value<(UNI)>() == 2995000, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
        let total_protocol_fees = protocol_fees<UNI>();
        assert!(total_protocol_fees > 0, 0);
        assert!(harvested_protocol_fees<UNI>() == 0, 0);
        let treasury_balance = treasury::balance<UNI>();
        harvest_protocol_fees<UNI>();
        assert!(protocol_fees<UNI>() == total_protocol_fees, 0);
        assert!(harvested_protocol_fees<UNI>() == total_protocol_fees, 0);
        assert!(treasury::balance<UNI>() == treasury_balance + (total_protocol_fees as u64), 0);
        assert!(pool_value<(UNI)>() == 2995000 - (total_protocol_fees as u64), 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    }
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // fun test_harvest_protocol_fees_more_than_liquidity(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<UNI>(depositor);
    //     managed_coin::register<UNI>(borrower);

    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);

    //     // Check status before repay
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
    //     assert!(risk_factor::share_fee() == risk_factor::default_share_fee(), 0);

    //     // execute
    //     managed_coin::mint<UNI>(owner, depositor_addr, 300000);
    //     deposit_for_internal<UNI>(depositor, depositor_addr, 300000, false);
    //     assert!(pool_value<(UNI)>() == 300000, 0);
    //     borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
    //     timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
    //     assert!(pool_value<(UNI)>() == 298995, 0);
    //     repay_internal<UNI>(borrower, 1000, false);
    //     assert!(pool_value<(UNI)>() == 299995, 0);
    //     assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
    //     let total_protocol_fees = protocol_fees<UNI>();
    //     let liquidity = liquidity<UNI>();
    //     assert!(liquidity > 0, 0);
    //     assert!((total_protocol_fees as u128) > liquidity, 0);
    //     assert!(harvested_protocol_fees<UNI>() == 0, 0);
    //     let treasury_balance = treasury::balance<UNI>();
    //     harvest_protocol_fees<UNI>();
    //     assert!(protocol_fees<UNI>() == total_protocol_fees, 0);
    //     assert!((harvested_protocol_fees<UNI>() as u128) == liquidity, 0);
    //     assert!((treasury::balance<UNI>() as u128) == (treasury_balance as u128) + liquidity, 0);
    //     assert!((pool_value<(UNI)>() as u128) == 299995 - liquidity, 0);

    //     let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
    //     assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    // }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_harvest_protocol_fees_at_zero(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        assert!(pool_value<(UNI)>() == 3000000, 0);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000000);
        timestamp::update_global_time_for_test((initial_sec + 604800) * 1000 * 1000); // + 1 Week
        assert!(pool_value<(UNI)>() == 1995000, 0);
        repay_internal<UNI>(borrower, 1000000, false);
        assert!(pool_value<(UNI)>() == 2995000, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
        let total_protocol_fees = protocol_fees<UNI>();
        assert!(total_protocol_fees > 0, 0);
        assert!(harvested_protocol_fees<UNI>() == 0, 0);
        let treasury_balance = treasury::balance<UNI>();
        harvest_protocol_fees<UNI>();
        assert!(protocol_fees<UNI>() == total_protocol_fees, 0);
        assert!(harvested_protocol_fees<UNI>() == total_protocol_fees, 0);
        assert!(treasury::balance<UNI>() == treasury_balance + (total_protocol_fees as u64), 0);
        assert!(pool_value<(UNI)>() == 2995000 - (total_protocol_fees as u64), 0);
        // harvest again
        treasury_balance = treasury::balance<UNI>();
        let pool_balance = pool_value<(UNI)>();
        harvest_protocol_fees<UNI>();
        assert!(protocol_fees<UNI>() - harvested_protocol_fees<UNI>() == 0, 0);
        assert!(treasury::balance<UNI>() == treasury_balance, 0);
        assert!(pool_value<(UNI)>() == pool_balance, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    }

    //// Convert
    #[test(owner = @leizd, aptos_framework = @aptos_framework)]
    fun test_normal_deposited_share_to_amount(owner: &signer, aptos_framework: &signer) acquires Storage, AssetManagerKeys {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_addr = signer::address_of(owner);

        assert!(normal_deposited_share_to_amount(key<UNI>(), 10000) == 0, 0);

        let asset_storage = borrow_mut_asset_storage<UNI>(borrow_global_mut<Storage>(owner_addr));
        asset_storage.total_normal_deposited_amount = 2000;
        asset_storage.total_normal_deposited_share = 1000;
        assert!(normal_deposited_share_to_amount(key<UNI>(), 10000) == 20000, 0);

        let asset_storage = borrow_mut_asset_storage<UNI>(borrow_global_mut<Storage>(owner_addr));
        asset_storage.total_normal_deposited_amount = 10000;
        asset_storage.total_normal_deposited_share = 50000;
        assert!(normal_deposited_share_to_amount(key<UNI>(), 200000) == 40000, 0);
    }
    #[test(owner = @leizd, aptos_framework = @aptos_framework)]
    fun test_conly_deposited_share_to_amount(owner: &signer, aptos_framework: &signer) acquires Storage, AssetManagerKeys {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_addr = signer::address_of(owner);

        assert!(conly_deposited_share_to_amount(key<UNI>(), 10000) == 0, 0);

        let asset_storage = borrow_mut_asset_storage<UNI>(borrow_global_mut<Storage>(owner_addr));
        asset_storage.total_conly_deposited_amount = 2000;
        asset_storage.total_conly_deposited_share = 1000;
        assert!(conly_deposited_share_to_amount(key<UNI>(), 10000) == 20000, 0);

        let asset_storage = borrow_mut_asset_storage<UNI>(borrow_global_mut<Storage>(owner_addr));
        asset_storage.total_conly_deposited_amount = 10000;
        asset_storage.total_conly_deposited_share = 50000;
        assert!(conly_deposited_share_to_amount(key<UNI>(), 200000) == 40000, 0);
    }
    #[test(owner = @leizd, aptos_framework = @aptos_framework)]
    fun test_borrowed_share_to_amount(owner: &signer, aptos_framework: &signer) acquires Storage, AssetManagerKeys {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_addr = signer::address_of(owner);

        assert!(borrowed_share_to_amount(key<UNI>(), 10000) == 0, 0);

        let asset_storage = borrow_mut_asset_storage<UNI>(borrow_global_mut<Storage>(owner_addr));
        asset_storage.total_borrowed_amount = 2000;
        asset_storage.total_borrowed_share = 1000;
        assert!(borrowed_share_to_amount(key<UNI>(), 10000) == 20000, 0);

        let asset_storage = borrow_mut_asset_storage<UNI>(borrow_global_mut<Storage>(owner_addr));
        asset_storage.total_borrowed_amount = 10000;
        asset_storage.total_borrowed_share = 50000;
        assert!(borrowed_share_to_amount(key<UNI>(), 200000) == 40000, 0);
    }
    // about overflow/underflow
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65550)]
    public fun test_deposit_when_deposited_will_be_over_u64_max(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        let max = constant::u64_max();

        managed_coin::mint<WETH>(owner, account_addr, max);
        deposit_for_internal<WETH>(account, account_addr, max, false);
        managed_coin::mint<WETH>(owner, account_addr, 1);
        deposit_for_internal<WETH>(account, account_addr, 1, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    fun test_withdraw_when_remains_will_be_underflow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        // test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1);
        deposit_for_internal<WETH>(account, account_addr, 1, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 2, false, false, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    fun test_borrow_when_borrowed_will_be_over_u64_max(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        let max = constant::u64_max();
        managed_coin::mint<UNI>(owner, depositor_addr, max);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        //// add liquidity
        deposit_for_internal<UNI>(depositor, depositor_addr, max, false);

        // borrow UNI
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, max);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65539)]
    fun test_repay_when_remains_will_be_underflow(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        assert!(risk_factor::entry_fee() == 0, 0);
        //// add liquidity
        managed_coin::mint<UNI>(owner, depositor_addr, 1);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1, false);

        // execute
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1);
        repay_internal<UNI>(borrower, 2, false);
    }

    // scenario
    #[test_only]
    public fun earn_interest_without_using_interest_rate_module_for_test<C>(
        rcomp: u128,
    ) acquires Storage {
        let owner_addr = permission::owner_address();
        let asset_storage_ref = borrow_mut_asset_storage<C>(borrow_global_mut<Storage>(owner_addr));
        save_calculated_values_by_rcomp(
            asset_storage_ref,
            rcomp,
            risk_factor::share_fee(),
        );
    }
    #[test(owner=@leizd,depositor1=@0x111,depositor2=@0x222,borrower1=@0x333,borrower2=@0x444,aptos_framework=@aptos_framework)]
    fun test_scenario_to_confirm_coins_moving(owner: &signer, depositor1: &signer, depositor2: &signer, borrower1: &signer, borrower2: &signer, aptos_framework: &signer) acquires Pool, Storage, AssetManagerKeys, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_addr = signer::address_of(owner);

        let depositor1_addr = signer::address_of(depositor1);
        account::create_account_for_test(depositor1_addr);
        managed_coin::register<WETH>(depositor1);
        managed_coin::mint<WETH>(owner, depositor1_addr, 500000);
        let depositor2_addr = signer::address_of(depositor2);
        account::create_account_for_test(depositor2_addr);
        managed_coin::register<WETH>(depositor2);

        let borrower1_addr = signer::address_of(borrower1);
        account::create_account_for_test(borrower1_addr);
        managed_coin::register<WETH>(borrower1);
        let borrower2_addr = signer::address_of(borrower2);
        account::create_account_for_test(borrower2_addr);
        managed_coin::register<WETH>(borrower2);

        // execute
        //// deposit
        deposit_for_internal<WETH>(depositor1, depositor1_addr, 400000, false);
        deposit_for_internal<WETH>(depositor1, depositor2_addr, 100000, false);
        assert!(total_normal_deposited_amount<WETH>() == 500000, 0);
        assert!(total_normal_deposited_share<WETH>() == 500000, 0);
        assert!(pool_value<(WETH)>() == 500000, 0);
        assert!(coin::balance<WETH>(depositor1_addr) == 0, 0);

        //// borrow
        borrow_for_internal<WETH>(borrower1_addr, borrower1_addr, 75000);
        assert!(total_borrowed_amount<WETH>() == 75375, 0);
        assert!(total_borrowed_share<WETH>() == 75375, 0);
        assert!(treasury::balance<WETH>() == 375, 0);
        borrow_for_internal<WETH>(borrower1_addr, borrower2_addr, 25000);
        assert!(total_borrowed_amount<WETH>() == 100500, 0);
        assert!(total_borrowed_share<WETH>() == 100500, 0);
        assert!(treasury::balance<WETH>() == 500, 0);

        assert!(pool_value<(WETH)>() == 399500, 0);
        assert!(coin::balance<WETH>(borrower1_addr) == 75000, 0);
        assert!(coin::balance<WETH>(borrower2_addr) == 25000, 0);

        //// update total_xxxx (instead of interest by accrue_interest)
        save_calculated_values_by_rcomp(
            borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)),
            interest_rate::precision() / 1000 * 100, // rcomp: 10% (dummy value)
            risk_factor::precision() / 1000 * 200 // share_fee: 20% (dummy value)
        );
        assert!(total_borrowed_amount<WETH>() == 100500 + 10050, 0);
        assert!(total_normal_deposited_amount<WETH>() == 500000 + 8040, 0);
        assert!(borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).protocol_fees == 2010, 0);
        assert!(borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).harvested_protocol_fees == 0, 0);

        //// repay
        managed_coin::mint<WETH>(owner, borrower1_addr, 88440 - 75000); // make up for the shortfall
        repay_internal<WETH>(borrower1, 88440, false); // 80400 + (10050 * 80%)
        assert!(total_borrowed_amount<WETH>() == 22110, 0); // 20100 + (10050 * 20%)
        assert!(total_borrowed_share<WETH>() == 20100, 0);
        ////// remains
        repay_internal<WETH>(borrower2, 22110, false);
        assert!(total_borrowed_amount<WETH>() == 0, 0);
        assert!(total_borrowed_share<WETH>() == 0, 0);
        assert!(pool_value<(WETH)>() == 500000 + 10050, 0);
        assert!(coin::balance<WETH>(borrower1_addr) == 0, 0);
        assert!(coin::balance<WETH>(borrower2_addr) == 25000 - 22110, 0);

        //// harvest
        harvest_protocol_fees<WETH>();
        assert!(borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).protocol_fees == 2010, 0);
        assert!(borrow_mut_asset_storage<WETH>(borrow_global_mut<Storage>(owner_addr)).harvested_protocol_fees == 2010, 0);
        assert!(pool_value<(WETH)>() == 510050 - 2010, 0);
        assert!(treasury::balance<WETH>() == 500 + 2010, 0);

        //// withdraw
        let (amount, share) = withdraw_for_internal<WETH>(depositor1_addr, depositor1_addr, 304824, false, false, 0); // 300000 + (8040 * 60%)
        assert!(amount == 304824, 0);
        assert!(share == 300000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 203216, 0); // 200000 + (8040 * 40%)
        assert!(total_normal_deposited_share<WETH>() == 200000, 0);
        assert!(pool_value<(WETH)>() == 508040 - 304824, 0);
        ////// remains
        let (amount, share) = withdraw_for_internal<WETH>(depositor1_addr, depositor2_addr, 200000, false, true, 0);
        assert!(amount == 203216, 0); // 200000 + (8040 * 40%)
        assert!(share == 200000, 0);
        assert!(total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(total_normal_deposited_share<WETH>() == 0, 0);
        assert!(pool_value<(WETH)>() == 0, 0);

        assert!(coin::balance<WETH>(depositor1_addr) == 304824, 0);
        assert!(coin::balance<WETH>(depositor2_addr) == 203216, 0);
    }
}
