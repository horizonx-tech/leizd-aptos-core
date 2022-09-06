/// Main point of interaction with Leizd Protocol
/// Users can:
/// # Deposit
/// # Withdraw
/// # Borrow
/// # Repay
/// # Liquidate
/// # Rebalance
module leizd::pool {
    use std::signer;
    use aptos_std::event;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use leizd::collateral;
    use leizd::collateral_only;
    use leizd::debt;
    use leizd::repository;
    use leizd::pool_type::{Self,Asset,Shadow};
    use leizd::stability_pool;
    use leizd::permission;
    use leizd::math128;
    use leizd::treasury;
    use leizd::interest_rate;
    use leizd::system_status;
    use leizd::usdz::{USDZ};
    use leizd::price_oracle;
    use leizd::constant;
    use leizd::dex_facade;
    use leizd::position;

    friend leizd::system_administrator;
    friend leizd::market;

    const E_IS_ALREADY_EXISTED: u64 = 1;
    const E_IS_NOT_EXISTED: u64 = 2;
    const E_DEX_DOES_NOT_HAVE_LIQUIDITY: u64 = 3;

    /// Asset Pool where users can deposit and borrow.
    /// Each asset is separately deposited into a pool.
    /// The pair for the asset can be stored as shadow.
    struct Pool<phantom C> has key {
        asset: coin::Coin<C>,
        shadow: coin::Coin<USDZ>,
        is_active: bool,
    }

    /// The total deposit amount and total borrowed amount can be updated
    /// in this struct. The collateral only asset is separately managed
    /// to calculate the borrowable amount in the pool.
    /// C: The coin type of the pool e.g. WETH / APT / USDC
    /// P: The pool type - Asset or Shadow.
    struct Storage<phantom C, phantom P> has key {
        total_deposits: u128,
        total_conly_deposits: u128, // collateral only
        total_borrows: u128,
        last_updated: u64,
        protocol_fees: u64,
    }

    // Events
    struct DepositEvent has store, drop {
        caller: address,
        depositor: address,
        amount: u64,
        is_collateral_only: bool,
        is_shadow: bool,
    }

    struct WithdrawEvent has store, drop {
        caller: address,
        depositor: address,
        receiver: address,
        amount: u64,
        is_collateral_only: bool,
        is_shadow: bool,
    }
    
    struct BorrowEvent has store, drop {
        caller: address,
        borrower: address,
        receiver: address,
        amount: u64,
        is_shadow: bool,
    }
    
    struct RepayEvent has store, drop {
        caller: address,
        amount: u64,
        is_shadow: bool,
    }
    
    struct LiquidateEvent has store, drop {
        caller: address,
        target: address,
        is_shadow: bool,
    }
    
    struct PoolEventHandle<phantom C> has key, store {
        deposit_event: event::EventHandle<DepositEvent>,
        withdraw_event: event::EventHandle<WithdrawEvent>,
        borrow_event: event::EventHandle<BorrowEvent>,
        repay_event: event::EventHandle<RepayEvent>,
        liquidate_event: event::EventHandle<LiquidateEvent>,
    }

    /// Initializes a pool with the coin the owner specifies.
    /// The caller is only owner and creates not only a pool but also other resources
    /// such as a treasury for the coin, an interest rate model, and coins of collaterals and debts.
    public entry fun init_pool<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        assert!(!is_pool_initialized<C>(), E_IS_ALREADY_EXISTED);
        assert!(dex_facade::has_liquidity<C>(), E_DEX_DOES_NOT_HAVE_LIQUIDITY);

        collateral::initialize<C>(owner);
        collateral_only::initialize<C>(owner);
        debt::initialize<C>(owner);
        treasury::initialize<C>(owner);
        repository::new_asset<C>(owner);
        interest_rate::initialize<C>(owner);
        stability_pool::init_pool<C>(owner);
        
        move_to(owner, Pool<C> {
            asset: coin::zero<C>(),
            shadow: coin::zero<USDZ>(),
            is_active: true
        });
        move_to(owner, default_storage<C,Asset>());
        move_to(owner, default_storage<C,Shadow>());
        move_to(owner, PoolEventHandle<C> {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
            liquidate_event: account::new_event_handle<LiquidateEvent>(owner),
        })
    }

    /// Deposits an asset or a shadow to the pool.
    /// If a user wants to protect the asset, it's possible that it can be used only for the collateral.
    /// C is a pool type and a user should select which pool to use.
    /// e.g. Deposit USDZ for WETH Pool -> deposit_for<WETH,Shadow>(x,x,x,x)
    /// e.g. Deposit WBTC for WBTC Pool -> deposit_for<WBTC,Asset>(x,x,x,x)
    public(friend) fun deposit_for<C,P>(
        account: &signer,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool,
    ) acquires Pool, Storage, PoolEventHandle {
        deposit_for_internal<C,P>(
            account,
            depositor_addr,
            amount,
            is_collateral_only
        );
    }

    /// Withdraws an asset or a shadow from the pool.
    public(friend) fun withdraw_for<C,P>(
        depositor: &signer,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool
    ) acquires Pool, Storage, PoolEventHandle {
        withdraw_for_internal<C,P>(
            depositor,
            receiver_addr,
            amount,
            is_collateral_only
        );
    }

    /// Borrows an asset or a shadow from the pool.
    public(friend) fun borrow_for<C,P>(
        account: &signer,
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
    ) acquires Pool, Storage, PoolEventHandle {
        borrow_for_internal<C,P>(account, borrower_addr, receiver_addr, amount);
    }

    /// Repays an asset or a shadow for the borrowed position.
    public entry fun repay<C,P>(
        account: &signer,
        amount: u64,
    ) acquires Pool, Storage, PoolEventHandle {
        repay_internal<C,P>(account, amount);
    }

    public entry fun liquidate<C>(
        account: &signer,
        target_addr: address,
        is_shadow: bool
    ) acquires Pool, Storage, PoolEventHandle {
        let liquidation_fee = repository::liquidation_fee();
        if (is_shadow) {
            assert!(is_shadow_solvent<C>(target_addr), 0);
            withdraw_shadow<C>(account, target_addr, constant::u64_max(), true, liquidation_fee);
            withdraw_shadow<C>(account, target_addr, constant::u64_max(), false, liquidation_fee);
        } else {
            assert!(is_asset_solvent<C>(target_addr), 0);
            withdraw_asset<C>(account, target_addr, constant::u64_max(), true, liquidation_fee);
            withdraw_asset<C>(account, target_addr, constant::u64_max(), false, liquidation_fee);
        };
        event::emit_event<LiquidateEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).liquidate_event,
            LiquidateEvent {
                caller: signer::address_of(account),
                target: target_addr,
                is_shadow
            }
        )
    }

    fun deposit_for_internal<C,P>(
        account: &signer,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool,
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(is_available<C>(), 0);

        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            deposit_shadow<C>(account, depositor_addr, amount, is_collateral_only);
        } else {
            deposit_asset<C>(account, depositor_addr, amount, is_collateral_only);
        };
        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).deposit_event,
            DepositEvent {
                caller: signer::address_of(account),
                depositor: depositor_addr,
                amount,
                is_collateral_only,
                is_shadow
            },
        );
    }

    fun withdraw_for_internal<C,P>(
        depositor: &signer,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(is_available<C>(), 0);

        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            withdraw_shadow<C>(depositor, receiver_addr, amount, is_collateral_only, 0);
        } else {
            withdraw_asset<C>(depositor, receiver_addr, amount, is_collateral_only, 0);
        };
        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).withdraw_event,
            WithdrawEvent {
                caller: signer::address_of(depositor),
                depositor: signer::address_of(depositor),
                receiver: receiver_addr,
                amount,
                is_collateral_only,
                is_shadow
            },
        );
    }

    fun borrow_for_internal<C,P>(
        account: &signer,
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(is_available<C>(), 0);
        position::initialize_if_necessary(account);

        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            borrow_shadow<C>(borrower_addr, receiver_addr, amount);
        } else {
            borrow_asset<C>(borrower_addr, receiver_addr, amount);
        };
        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).borrow_event,
            BorrowEvent {
                caller: signer::address_of(account),
                borrower: borrower_addr,
                receiver: receiver_addr,
                amount,
                is_shadow
            },
        );
    }

    fun repay_internal<C,P>(
        account: &signer,
        amount: u64,
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(is_available<C>(), 0);

        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            repay_shadow<C>(account, amount);
        } else {
            repay_asset<C>(account, amount);
        };
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).repay_event,
            RepayEvent {
                caller: signer::address_of(account),
                amount,
                is_shadow
            },
        );
    }

    fun deposit_asset<C>(
        account: &signer,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool
    ) acquires Pool, Storage {
        let storage_ref = borrow_global_mut<Storage<C,Asset>>(@leizd);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);

        coin::merge(&mut pool_ref.asset, coin::withdraw<C>(account, amount));
        deposit_common<C,Asset>(
            depositor_addr,
            (amount as u128),
            is_collateral_only,
            storage_ref
        );
    }

    fun deposit_shadow<C>(
        account: &signer,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool
    ) acquires Pool, Storage {
        let storage_ref = borrow_global_mut<Storage<C,Shadow>>(@leizd);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);

        accrue_interest<C,Shadow>(storage_ref);

        coin::merge(&mut pool_ref.shadow, coin::withdraw<USDZ>(account, amount));
        deposit_common<C,Shadow>(
            depositor_addr,
            (amount as u128),
            is_collateral_only,
            storage_ref
        );
    }

    fun deposit_common<C,P>(
        depositor_addr: address,
        amount128: u128,
        is_collateral_only: bool,
        storage_ref: &mut Storage<C,P>
    ) {
        if (is_collateral_only) {
            let collateral_share = math128::to_share(
                amount128,
                storage_ref.total_conly_deposits,
                collateral_only::supply<C,P>()
            );
            storage_ref.total_conly_deposits = storage_ref.total_conly_deposits + amount128;
            collateral_only::mint<C,P>(depositor_addr, (collateral_share as u64)); 
        } else {
            let collateral_share = math128::to_share(
                amount128,
                storage_ref.total_deposits,
                collateral::supply<C,P>()
            );
            storage_ref.total_deposits = storage_ref.total_deposits + amount128;
            collateral::mint<C,P>(depositor_addr, (collateral_share as u64));
        };
    }

    fun withdraw_asset<C>(
        depositor: &signer,
        reciever_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64
    ) acquires Pool, Storage {
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Asset>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);
        collect_asset_fee<C>(pool_ref, liquidation_fee);

        let amount_to_transfer = amount - liquidation_fee;
        coin::deposit<C>(reciever_addr, coin::extract(&mut pool_ref.asset, amount_to_transfer));
        withdraw_common<C,Asset>(depositor, (amount as u128), is_collateral_only, storage_ref);
        assert!(is_asset_solvent<C>(signer::address_of(depositor)),0);
    }

    fun withdraw_shadow<C>(
        depositor: &signer,
        reciever_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64
    ) acquires Pool, Storage { 
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Shadow>>(@leizd);

        accrue_interest<C,Shadow>(storage_ref);
        collect_shadow_fee<C>(pool_ref, liquidation_fee);

        let amount_to_transfer = amount - liquidation_fee;
        coin::deposit<USDZ>(reciever_addr, coin::extract(&mut pool_ref.shadow, amount_to_transfer));
        withdraw_common<C,Shadow>(depositor, (amount as u128), is_collateral_only, storage_ref);
        assert!(is_shadow_solvent<C>(signer::address_of(depositor)),0);
    }

    fun withdraw_common<C,P>(
        depositor: &signer,
        amount128: u128,
        is_collateral_only: bool,
        storage_ref: &mut Storage<C,P>
    ) {
        let depositor_addr = signer::address_of(depositor);
        let burned_share;
        let withdrawn_amount;
        if (amount128 == constant::u128_max()) {
            burned_share = collateral_balance<C,P>(depositor_addr, is_collateral_only);
            if (is_collateral_only) {
                withdrawn_amount = math128::to_amount((burned_share as u128), storage_ref.total_conly_deposits, collateral_supply<C,P>(is_collateral_only));
            } else {
                withdrawn_amount = math128::to_amount((burned_share as u128), storage_ref.total_deposits, collateral_supply<C,P>(is_collateral_only));
            };
        } else {
            if (is_collateral_only) {
                burned_share = (math128::to_share_roundup(amount128, storage_ref.total_conly_deposits, collateral_supply<C,P>(is_collateral_only)) as u64);
            } else {
                burned_share = (math128::to_share_roundup(amount128, storage_ref.total_deposits, collateral_supply<C,P>(is_collateral_only)) as u64);
            };
            withdrawn_amount = amount128;
        };

        if (is_collateral_only) {
            storage_ref.total_conly_deposits = storage_ref.total_conly_deposits - (withdrawn_amount as u128);
            collateral_only::burn<C,P>(depositor, burned_share);
        } else {
            storage_ref.total_deposits = storage_ref.total_deposits - (withdrawn_amount as u128);
            collateral::burn<C,P>(depositor, burned_share);
        };
    }


    fun borrow_asset<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64
    ) acquires Pool, Storage {
        assert!(liquidity<C>(false) >= (amount as u128), 0);

        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Asset>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);

        let fee = calculate_entry_fee(amount);
        collect_asset_fee<C>(pool_ref, fee);

        let deposited = coin::extract(&mut pool_ref.asset, amount);
        coin::deposit<C>(receiver_addr, deposited);
        borrow_common<C,Asset>(borrower_addr, amount, fee, storage_ref);
        assert!(is_asset_solvent<C>(borrower_addr),0);
        position::take_borrow_position<C,Asset>(borrower_addr, amount);
    }

    fun borrow_shadow<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64
    ) acquires Pool, Storage {
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Shadow>>(@leizd);

        accrue_interest<C,Shadow>(storage_ref);

        let fee = calculate_entry_fee(amount);
        collect_shadow_fee<C>(pool_ref, fee);

        if (storage_ref.total_deposits - storage_ref.total_conly_deposits < (amount as u128)) {
            // check the staiblity left
            let left = stability_pool::left();
            assert!(left >= (amount as u128), 0);
            borrow_shadow_from_stability_pool<C>(receiver_addr, amount);
            fee = fee + stability_pool::stability_fee_amount(amount);
        } else {
            let deposited = coin::extract(&mut pool_ref.shadow, amount);
            coin::deposit<USDZ>(receiver_addr, deposited);
        };

        borrow_common<C,Shadow>(borrower_addr, amount, fee, storage_ref);
        assert!(is_shadow_solvent<C>(borrower_addr),0);
        position::take_borrow_position<C,Shadow>(borrower_addr, amount);
    }


    fun borrow_common<C,P>(
        depositor_addr: address,
        amount: u64,
        fee: u64,
        storage_ref: &mut Storage<C,P>
    ) {
        let debt_share = math128::to_share_roundup(((amount + fee) as u128), storage_ref.total_borrows, debt::supply<C,P>());
        storage_ref.total_borrows = storage_ref.total_borrows + (amount as u128) + (fee as u128);
        debt::mint<C,P>(depositor_addr, (debt_share as u64));
    }

    fun borrow_shadow_from_stability_pool<C>(receiver_addr: address, amount: u64) {
        let borrowed = stability_pool::borrow<C>(receiver_addr, amount);
        coin::deposit(receiver_addr, borrowed);
    }

    /// Repays the shadow to the stability pool if someone has already borrowed from the pool.
    /// @return repaid amount
    fun repay_to_stability_pool<C>(account: &signer, amount: u64): u64 {
        let left = stability_pool::left();
        if (left == 0) {
            return 0
        } else if (left >= (amount as u128)) {
            stability_pool::repay<C>(account, amount);
            return amount
        } else {
            stability_pool::repay<C>(account, (left as u64));
            return (left as u64)
        }
    }

    fun repay_asset<C>(
        account: &signer,
        amount: u64
    ) acquires Pool, Storage {
        let account_addr = signer::address_of(account);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Asset>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);

        let (repaid_amount, repaid_share) = calc_debt_amount_and_share<C,Asset>(account_addr, storage_ref.total_borrows, amount);

        let withdrawn = coin::withdraw<C>(account, repaid_amount);
        coin::merge(&mut pool_ref.asset, withdrawn);

        storage_ref.total_borrows = storage_ref.total_borrows - (repaid_amount as u128);
        debt::burn<C,Asset>(account, repaid_share);
        position::cancel_borrow_position<C,Asset>(signer::address_of(account), amount);
    }

    fun repay_shadow<C>(
        account: &signer,
        amount: u64
    ) acquires Pool, Storage {
        let account_addr = signer::address_of(account);
        let storage_ref = borrow_global_mut<Storage<C,Shadow>>(@leizd);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);

        accrue_interest<C,Shadow>(storage_ref);

        let (repaid_amount, repaid_share) = calc_debt_amount_and_share<C,Shadow>(account_addr, storage_ref.total_borrows, amount);

        let withdrawn = coin::withdraw<USDZ>(account, repaid_amount);
        coin::merge(&mut pool_ref.shadow, withdrawn);

        storage_ref.total_borrows = storage_ref.total_borrows - (repaid_amount as u128);
        debt::burn<C,Shadow>(account, repaid_share);
        position::cancel_borrow_position<C,Shadow>(signer::address_of(account), amount);
    }

    public fun is_available<C>(): bool acquires Pool {
        let system_is_active = system_status::status();
        assert!(is_pool_initialized<C>(), E_IS_NOT_EXISTED);
        let pool_ref = borrow_global<Pool<C>>(@leizd);
        system_is_active && pool_ref.is_active 
    }

    public fun is_pool_initialized<C>(): bool {
        exists<Pool<C>>(@leizd)
    }

    public fun calc_debt_amount_and_share<C,P>(
        account_addr: address,
        total_borrows: u128,
        amount: u64
    ): (u64, u64) {
        let borrower_debt_share = debt::balance_of<C,P>(account_addr);
        let debt_supply = debt::supply<C,P>();
        let max_amount = (math128::to_amount_roundup((borrower_debt_share as u128), total_borrows, debt_supply) as u64);

        let _amount = 0;
        let _repay_share = 0;
        if (amount >= max_amount) {
            _amount = max_amount;
            _repay_share = borrower_debt_share;
        } else {
            _amount = amount;
            _repay_share = (math128::to_share((amount as u128), total_borrows, debt_supply) as u64);
        };
        (_amount, _repay_share)
    }

    public entry fun collateral_value<C,P>(account: &signer): u64 {
        let account_addr = signer::address_of(account);
        let asset = collateral::balance_of<C,Asset>(account_addr) + collateral_only::balance_of<C,Asset>(account_addr);
        let shadow = collateral::balance_of<C,Shadow>(account_addr) + collateral_only::balance_of<C,Shadow>(account_addr);

        asset * price_oracle::price<C>() + shadow * price_oracle::price<USDZ>()
    }

    public entry fun debt_value<C,P>(account: &signer): u64 {
        let account_addr = signer::address_of(account);
        let asset = debt::balance_of<C,Asset>(account_addr);
        let shadow = debt::balance_of<C,Shadow>(account_addr);

        asset * price_oracle::price<C>() + shadow * price_oracle::price<USDZ>()
    }

    public entry fun is_asset_solvent<C>(account_addr: address): bool {
        is_solvent<C,Asset,Shadow>(account_addr)
    }

    public entry fun is_shadow_solvent<C>(account_addr: address): bool {
        is_solvent<C,Shadow,Asset>(account_addr)
    }

    fun is_solvent<COIN,COL,DEBT>(account_addr: address): bool {
        let user_ltv = user_ltv<COIN,COL,DEBT>(account_addr);
        user_ltv <= repository::lt<COIN>() / constant::e18_u64()
    }

    public fun user_ltv<COIN,COL,DEBT>(account_addr: address): u64 {
        let collateral = collateral::balance_of<COIN,COL>(account_addr) + collateral_only::balance_of<COIN,COL>(account_addr);
        let collateral_value = collateral * price_oracle::price<COIN>();
        let debt = debt::balance_of<COIN,DEBT>(account_addr);
        let debt_value = debt * price_oracle::price<COIN>();

        let user_ltv = if (debt_value == 0) 0 else collateral_value / debt_value;
        user_ltv
    }

    /// This function is called on every user action.
    fun accrue_interest<C,P>(storage_ref: &mut Storage<C,P>) {
        let now = timestamp::now_microseconds();

        // This is the first time
        if (storage_ref.last_updated == 0) {
            storage_ref.last_updated = now;
            return
        };

        if (storage_ref.last_updated == now) {
            return
        };

        let protocol_share_fee = repository::share_fee();
        let rcomp = interest_rate::update_interest_rate<C>(
            storage_ref.total_deposits,
            storage_ref.total_borrows,
            storage_ref.last_updated,
            now,
        );
        let accrued_interest = storage_ref.total_borrows * rcomp / interest_rate::precision();
        let protocol_share = accrued_interest * (protocol_share_fee as u128) / interest_rate::precision();
        let new_protocol_fees = storage_ref.protocol_fees + (protocol_share as u64);

        let depositors_share = accrued_interest - protocol_share;
        storage_ref.total_borrows = storage_ref.total_borrows + accrued_interest;
        storage_ref.total_deposits = storage_ref.total_deposits + depositors_share;
        storage_ref.protocol_fees = new_protocol_fees;
        storage_ref.last_updated = now;
    }

    fun collect_asset_fee<C>(pool_ref: &mut Pool<C>, liquidation_fee: u64) {
        let fee_extracted = coin::extract(&mut pool_ref.asset, liquidation_fee);
        treasury::collect_asset_fee<C>(fee_extracted);
    }

    fun collect_shadow_fee<C>(pool_ref: &mut Pool<C>, liquidation_fee: u64) {
        let fee_extracted = coin::extract(&mut pool_ref.shadow, liquidation_fee);
        treasury::collect_shadow_fee<C>(fee_extracted);
    }


    fun default_storage<C,P>(): Storage<C,P> {
        Storage<C,P>{
            total_deposits: 0,
            total_conly_deposits: 0,
            total_borrows: 0,
            last_updated: 0,
            protocol_fees: 0,
        }
    }

    fun collateral_balance<C,P>(account_addr: address, is_collateral_only: bool): u64 {
        if (is_collateral_only) {
            collateral_only::balance_of<C,P>(account_addr)
        } else {
            collateral::balance_of<C,P>(account_addr)
        }
    }

    fun collateral_supply<C,P>(is_collateral_only: bool): u128 {
        if (is_collateral_only) {
            collateral_only::supply<C,P>()
        } else {
            collateral::supply<C,P>()
        }
    }

    fun calculate_entry_fee(value: u64): u64 {
        value * repository::entry_fee() / repository::precision() // TODO: rounded up
    }

    fun calculate_share_fee(value: u64): u64 {
        value * repository::share_fee() / repository::precision() // TODO: rounded up
    }

    fun calculate_liquidation_fee(value: u64): u64 {
        value * repository::liquidation_fee() / repository::precision() // TODO: rounded up
    }

    public entry fun liquidity<C>(is_shadow: bool): u128 acquires Storage, Pool {
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        if (is_shadow) {
            let storage_ref = borrow_global<Storage<C,Shadow>>(@leizd);
            (coin::value(&pool_ref.shadow) as u128) - storage_ref.total_conly_deposits
        } else {
            let storage_ref = borrow_global<Storage<C,Asset>>(@leizd);
            (coin::value(&pool_ref.asset) as u128) - storage_ref.total_conly_deposits
        }
    }

    public entry fun total_deposits<C,P>(): u128 acquires Storage {
        borrow_global<Storage<C,P>>(@leizd).total_deposits
    }

    public entry fun total_conly_deposits<C,P>(): u128 acquires Storage {
        borrow_global<Storage<C,P>>(@leizd).total_conly_deposits
    }

    public entry fun total_borrows<C,P>(): u128 acquires Storage {
        borrow_global<Storage<C,P>>(@leizd).total_borrows
    }

    public entry fun last_updated<C,P>(): u64 acquires Storage {
        borrow_global<Storage<C,P>>(@leizd).last_updated
    }

    public(friend) entry fun update_status<C>(active: bool) acquires Pool {
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        pool_ref.is_active = active;
    }

    // #[test_only]
    // use aptos_std::debug;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::test_coin::{Self,USDC,USDT,WETH,UNI};
    #[test_only]
    use leizd::dummy;
    #[test_only]
    use leizd::usdz;
    #[test_only]
    use leizd::initializer;
    #[test(owner=@leizd)]
    public entry fun test_init_pool(owner: &signer) acquires Pool {
        // Prerequisite
        let owner_address = signer::address_of(owner);
        account::create_account_for_test(owner_address);
        test_coin::init_weth(owner);
        initializer::initialize(owner);

        init_pool<WETH>(owner);

        assert!(exists<Pool<WETH>>(owner_address), 0);
        let pool = borrow_global<Pool<WETH>>(owner_address);
        assert!(pool.is_active, 0);
        assert!(coin::value<WETH>(&pool.asset) == 0, 0);
        assert!(coin::value<USDZ>(&pool.shadow) == 0, 0);
        assert!(is_available<WETH>(), 0);
        assert!(is_pool_initialized<WETH>(), 0);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 1)]
    public entry fun test_init_pool_twice(owner: &signer) {
        // Prerequisite
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_weth(owner);
        initializer::initialize(owner);

        init_pool<WETH>(owner);
        init_pool<WETH>(owner);
    }

    #[test(owner=@leizd)]
    public entry fun test_is_pool_initialized(owner: &signer) {
        // Prerequisite
        let owner_address = signer::address_of(owner);
        account::create_account_for_test(owner_address);
        initializer::initialize(owner);
        //// init coin & pool
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
    fun setup_for_test_to_initialize_coins_and_pools(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initializer::initialize(owner);
        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
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
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH,Asset>(account, account_addr, 800000, false);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(total_deposits<WETH,Asset>() == 800000, 0);
        assert!(total_conly_deposits<WETH,Asset>() == 0, 0);
        assert!(collateral::balance_of<WETH, Asset>(account_addr) == 800000, 0);
        assert!(collateral_only::balance_of<WETH, Asset>(account_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<DepositEvent>(&event_handle.deposit_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_with_same_as_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_for_internal<WETH,Asset>(account, account_addr, 1000000, false);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(total_deposits<WETH,Asset>() == 1000000, 0);
        assert!(total_conly_deposits<WETH,Asset>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_deposit_with_more_than_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_for_internal<WETH,Asset>(account, account_addr, 1000001, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_twice_sequentially(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        timestamp::update_global_time_for_test(1662125899730897);
        deposit_for_internal<WETH,Asset>(account, account_addr, 400000, false);
        timestamp::update_global_time_for_test(1662125899830897);
        deposit_for_internal<WETH,Asset>(account, account_addr, 400000, false);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(total_deposits<WETH,Asset>() == 800000, 0);
        assert!(total_conly_deposits<WETH,Asset>() == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_by_two(owner: &signer, account1: &signer, account2: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);
        initializer::register<WETH>(account1);
        initializer::register<WETH>(account2);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        managed_coin::mint<WETH>(owner, account2_addr, 1000000);

        deposit_for_internal<WETH,Asset>(account1, account1_addr, 800000, false);
        deposit_for_internal<WETH,Asset>(account2, account2_addr, 200000, false);
        assert!(coin::balance<WETH>(account1_addr) == 200000, 0);
        assert!(coin::balance<WETH>(account2_addr) == 800000, 0);
        assert!(total_deposits<WETH,Asset>() == 1000000, 0);
        assert!(total_conly_deposits<WETH,Asset>() == 0, 0);
        assert!(collateral::balance_of<WETH,Asset>(account1_addr) == 800000, 0);
        assert!(collateral::balance_of<WETH,Asset>(account2_addr) == 200000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 2)]
    public entry fun test_deposit_with_dummy_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        dummy::init_weth(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        initializer::register<dummy::WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        managed_coin::mint<dummy::WETH>(owner, account_addr, 1000000);

        deposit_for_internal<dummy::WETH,Asset>(account, account_addr, 800000, false);
    }

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH,Asset>(account, account_addr, 800000, true);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(total_deposits<WETH,Asset>() == 0, 0);
        assert!(total_conly_deposits<WETH,Asset>() == 800000, 0);
        assert!(collateral::balance_of<WETH, Asset>(account_addr) == 0, 0);
        assert!(collateral_only::balance_of<WETH, Asset>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        initializer::register<USDZ>(account);

        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);
        usdz::mint_for_test(account_addr, 1000000);
        assert!(coin::balance<USDZ>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH,Shadow>(account, account_addr, 800000, false);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);
        assert!(total_deposits<WETH,Asset>() == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 200000, 0);
        assert!(total_deposits<WETH,Shadow>() == 800000, 0);
        assert!(total_conly_deposits<WETH,Shadow>() == 0, 0);
        assert!(collateral::balance_of<WETH, Shadow>(account_addr) == 800000, 0);
        assert!(collateral_only::balance_of<WETH, Shadow>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        initializer::register<USDZ>(account);

        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal<WETH,Shadow>(account, account_addr, 800000, true);
        assert!(coin::balance<USDZ>(account_addr) == 200000, 0);
        assert!(total_deposits<WETH,Shadow>() == 0, 0);
        assert!(total_conly_deposits<WETH,Shadow>() == 800000, 0);
        assert!(collateral::balance_of<WETH, Shadow>(account_addr) == 0, 0);
        assert!(collateral_only::balance_of<WETH, Shadow>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_with_all_patterns(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        initializer::register<USDZ>(account);

        managed_coin::mint<WETH>(owner, account_addr, 10);
        usdz::mint_for_test(account_addr, 10);

        deposit_for_internal<WETH,Asset>(account, account_addr, 1, false);
        deposit_for_internal<WETH,Asset>(account, account_addr, 2, true);
        deposit_for_internal<WETH,Shadow>(account, account_addr, 3, false);
        deposit_for_internal<WETH,Shadow>(account, account_addr, 4, true);

        assert!(coin::balance<WETH>(account_addr) == 7, 0);
        assert!(coin::balance<USDZ>(account_addr) == 3, 0);
        assert!(total_deposits<WETH,Asset>() == 1, 0);
        assert!(total_conly_deposits<WETH,Asset>() == 2, 0);
        assert!(total_deposits<WETH,Shadow>() == 3, 0);
        assert!(total_conly_deposits<WETH,Shadow>() == 4, 0);
        assert!(liquidity<WETH>(false) == 1, 0);
        assert!(liquidity<WETH>(true) == 3, 0);
        assert!(collateral::balance_of<WETH, Asset>(account_addr) == 1, 0);
        assert!(collateral_only::balance_of<WETH, Asset>(account_addr) == 2, 0);
        assert!(collateral::balance_of<WETH, Shadow>(account_addr) == 3, 0);
        assert!(collateral_only::balance_of<WETH, Shadow>(account_addr) == 4, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<DepositEvent>(&event_handle.deposit_event) == 4, 0);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH,Asset>(account, account_addr, 700000, false);
        withdraw_for_internal<WETH,Asset>(account, account_addr, 600000, false);

        assert!(coin::balance<WETH>(account_addr) == 900000, 0);
        assert!(collateral::balance_of<WETH, Asset>(account_addr) == 100000, 0);
        assert!(total_deposits<WETH,Asset>() == 100000, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_same_as_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit_for_internal<WETH,Asset>(account, account_addr, 30, false);
        withdraw_for_internal<WETH,Asset>(account, account_addr, 30, false);

        assert!(coin::balance<WETH>(account_addr) == 100, 0);
        assert!(collateral::balance_of<WETH, Asset>(account_addr) == 0, 0);
        assert!(total_deposits<WETH,Asset>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit_for_internal<WETH,Asset>(account, account_addr, 50, false);
        withdraw_for_internal<WETH,Asset>(account, account_addr, 51, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::register<USDZ>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_for_internal<WETH,Asset>(account, account_addr, 700000, true);
        withdraw_for_internal<WETH,Asset>(account, account_addr, 600000, true);

        assert!(coin::balance<WETH>(account_addr) == 900000, 0);
        assert!(total_deposits<WETH,Asset>() == 0, 0);
        assert!(total_conly_deposits<WETH,Asset>() == 100000, 0);
        assert!(collateral::balance_of<WETH, Asset>(account_addr) == 0, 0);
        assert!(collateral_only::balance_of<WETH, Asset>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal<WETH,Shadow>(account, account_addr, 700000, false);
        withdraw_for_internal<WETH,Shadow>(account, account_addr, 600000, false);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 900000, 0);
        assert!(total_deposits<WETH,Shadow>() == 100000, 0);
        assert!(total_conly_deposits<WETH,Shadow>() == 0, 0);
        assert!(collateral::balance_of<WETH, Shadow>(account_addr) == 100000, 0);
        assert!(collateral_only::balance_of<WETH, Shadow>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal<WETH,Shadow>(account, account_addr, 700000, true);
        withdraw_for_internal<WETH,Shadow>(account, account_addr, 600000, true);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 900000, 0);
        assert!(total_deposits<WETH,Asset>() == 0, 0);
        assert!(total_deposits<WETH,Shadow>() == 0, 0);
        assert!(total_conly_deposits<WETH,Asset>() == 0, 0);
        assert!(total_conly_deposits<WETH,Shadow>() == 100000, 0);
        assert!(collateral::balance_of<WETH, Shadow>(account_addr) == 0, 0);
        assert!(collateral_only::balance_of<WETH, Shadow>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_all_patterns(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        initializer::register<USDZ>(account);

        managed_coin::mint<WETH>(owner, account_addr, 20);
        usdz::mint_for_test(account_addr, 20);

        deposit_for_internal<WETH,Asset>(account, account_addr, 10, false);
        deposit_for_internal<WETH,Asset>(account, account_addr, 10, true);
        deposit_for_internal<WETH,Shadow>(account, account_addr, 10, false);
        deposit_for_internal<WETH,Shadow>(account, account_addr, 10, true);

        withdraw_for_internal<WETH,Asset>(account, account_addr, 1, false);
        withdraw_for_internal<WETH,Asset>(account, account_addr, 2, true);
        withdraw_for_internal<WETH,Shadow>(account, account_addr, 3, false);
        withdraw_for_internal<WETH,Shadow>(account, account_addr, 4, true);

        assert!(coin::balance<WETH>(account_addr) == 3, 0);
        assert!(coin::balance<USDZ>(account_addr) == 7, 0);
        assert!(total_deposits<WETH,Asset>() == 9, 0);
        assert!(total_conly_deposits<WETH,Asset>() == 8, 0);
        assert!(total_deposits<WETH,Shadow>() == 7, 0);
        assert!(total_conly_deposits<WETH,Shadow>() == 6, 0);
        assert!(liquidity<WETH>(false) == 9, 0);
        assert!(liquidity<WETH>(true) == 7, 0);

        assert!(collateral::balance_of<WETH, Asset>(account_addr) == 9, 0);
        assert!(collateral_only::balance_of<WETH, Asset>(account_addr) == 8, 0);
        assert!(collateral::balance_of<WETH, Shadow>(account_addr) == 7, 0);
        assert!(collateral_only::balance_of<WETH, Shadow>(account_addr) == 6, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 4, 0);
    }

    // for borrow
    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_uni(owner: &signer, account1: &signer, account2: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);
        initializer::register<WETH>(account1);
        initializer::register<UNI>(account1);
        initializer::register<USDZ>(account1);
        initializer::register<WETH>(account2);
        initializer::register<UNI>(account2);
        initializer::register<USDZ>(account2);

        managed_coin::mint<UNI>(owner, account1_addr, 1000000);
        usdz::mint_for_test(account1_addr, 1000000);

        managed_coin::mint<WETH>(owner, account2_addr, 1000000);

        // Lender: 
        // deposit USDZ for WETH
        // deposit UNI
        deposit_for_internal<WETH,Shadow>(account1, account1_addr, 800000, false);
        deposit_for_internal<UNI,Asset>(account1, account1_addr, 800000, false);

        // Borrower:
        // deposit WETH
        // borrow  USDZ
        deposit_for_internal<WETH,Asset>(account2, account2_addr, 600000, false);
        borrow_for_internal<WETH,Shadow>(account2, account2_addr, account2_addr, 300000);
        assert!(coin::balance<WETH>(account2_addr) == 400000, 0);
        assert!(coin::balance<USDZ>(account2_addr) == 300000, 0);

        // Borrower:
        // deposit USDZ for UNI
        // borrow UNI
        deposit_for_internal<UNI,Shadow>(account2, account2_addr, 200000, false);
        borrow_for_internal<UNI,Asset>(account2, account2_addr, account2_addr, 100000);
        assert!(coin::balance<UNI>(account2_addr) == 100000, 0);
        assert!(coin::balance<USDZ>(account2_addr) == 100000, 0);

        // check about fee
        assert!(repository::entry_fee() == repository::default_entry_fee(), 0);
        assert!(debt::balance_of<WETH,Shadow>(account2_addr) == 301500, 0);
        assert!(debt::balance_of<UNI,Asset>(account2_addr) == 100500, 0);
        assert!(treasury::balance_of_shadow<WETH>() == 1500, 0);
        assert!(treasury::balance_of_asset<UNI>() == 500, 0);
    }
    #[test(owner=@leizd,lender=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_(owner: &signer, aptos_framework: &signer) {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    }

    // for repay
    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_uni(owner: &signer, account1: &signer, account2: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);
        initializer::register<WETH>(account1);
        initializer::register<UNI>(account1);
        initializer::register<USDZ>(account1);
        initializer::register<WETH>(account2);
        initializer::register<UNI>(account2);
        initializer::register<USDZ>(account2);

        usdz::mint_for_test(account1_addr, 1000000);
        managed_coin::mint<UNI>(owner, account1_addr, 1000000);
        managed_coin::mint<WETH>(owner, account2_addr, 1000000);

        // Lender: 
        // deposit USDZ for WETH
        // deposit UNI
        deposit_for_internal<WETH,Shadow>(account1, account1_addr, 800000, false);
        deposit_for_internal<UNI,Asset>(account1, account1_addr, 800000, false);

        // Borrower:
        // deposit WETH
        // borrow  USDZ
        deposit_for_internal<WETH,Asset>(account2, account2_addr, 600000, false);
        borrow_for_internal<WETH,Shadow>(account2, account2_addr, account2_addr, 300000);

        // Borrower:
        // deposit USDZ for UNI
        // borrow UNI
        deposit_for_internal<UNI,Shadow>(account2, account2_addr, 200000, false);
        borrow_for_internal<UNI,Asset>(account2, account2_addr, account2_addr, 100000);

        // Check status before repay
        assert!(repository::entry_fee() == repository::default_entry_fee(), 0);
        assert!(debt::balance_of<WETH,Shadow>(account2_addr) == 301500, 0);
        assert!(debt::balance_of<UNI,Asset>(account2_addr) == 100500, 0);
        
        // Borrower:
        // repay UNI
        repay_internal<UNI,Asset>(account2, 100000);
        assert!(coin::balance<UNI>(account2_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account2_addr) == 100000, 0);
        assert!(debt::balance_of<UNI,Asset>(account2_addr) == 500, 0); // TODO: 0.5% entry fee + 0.0% interest

        // Borrower:
        // repay USDZ

        // withdraw<UNI>(account2, 200000, false, true); // TODO: error in position#update_position (EKEY_ALREADY_EXISTS)
        // repay<WETH>(account2, 300000, true);
        // assert!(coin::balance<USDZ>(account2_addr) == 0, 0);
        // assert!(debt::balance_of<WETH,Shadow>(account2_addr) == 1500, 0);
    }
}