module leizd_aptos_treasury::treasury {

    use std::signer;
    use aptos_framework::coin;
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::usdz::{USDZ};

    struct Treasury<phantom C> has key {
        asset: coin::Coin<C>,
        shadow: coin::Coin<USDZ>,
    }

    public fun initialize<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, Treasury<C> {
            asset: coin::zero<C>(),
            shadow: coin::zero<USDZ>()
        });
    }

    public entry fun collect_asset_fee<C>(coin: coin::Coin<C>) acquires Treasury {
        let treasury_ref = borrow_global_mut<Treasury<C>>(permission::owner_address());
        coin::merge<C>(&mut treasury_ref.asset, coin);
    }

    public entry fun collect_shadow_fee<C>(coin: coin::Coin<USDZ>) acquires Treasury {
        let treasury_ref = borrow_global_mut<Treasury<C>>(permission::owner_address());
        coin::merge<USDZ>(&mut treasury_ref.shadow, coin);
    }

    public entry fun withdraw_asset_fee<C>(owner: &signer, amount: u64) acquires Treasury {
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);

        let treasury_ref = borrow_global_mut<Treasury<C>>(owner_address);
        let deposited = coin::extract(&mut treasury_ref.asset, amount);
        coin::deposit<C>(owner_address, deposited);
    }

    public entry fun withdraw_shadow_fee<C>(owner: &signer, amount: u64) acquires Treasury {
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);

        let treasury_ref = borrow_global_mut<Treasury<C>>(owner_address);
        let deposited = coin::extract(&mut treasury_ref.shadow, amount);
        coin::deposit<USDZ>(owner_address, deposited);
    }

    #[test_only]
    public fun balance_of_asset<C>(): u64 acquires Treasury {
        let treasury_ref = borrow_global_mut<Treasury<C>>(permission::owner_address());
        coin::value<C>(&treasury_ref.asset)
    }
    #[test_only]
    public fun balance_of_shadow<C>(): u64 acquires Treasury {
        let treasury_ref = borrow_global_mut<Treasury<C>>(permission::owner_address());
        coin::value<USDZ>(&treasury_ref.shadow)
    }
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_trove::usdz;
    #[test_only]
    use leizd_aptos_common::test_coin::{Self, WETH};
    #[test(owner = @leizd_aptos_treasury, account = @0x111)]
    fun test_end_to_end(owner: &signer, account: &signer) acquires Treasury {
        // prepares
        let owner_address = permission::owner_address();
        let account_address = signer::address_of(account);
        account::create_account_for_test(owner_address);
        account::create_account_for_test(account_address);
        test_coin::init_weth(owner);
        usdz::initialize_for_test(owner);
        managed_coin::register<USDZ>(owner);
        managed_coin::register<WETH>(account);
        managed_coin::register<USDZ>(account);
        managed_coin::mint<WETH>(owner, account_address, 1000);
        usdz::mint_for_test(account_address, 500);

        initialize<WETH>(owner);
        assert!(balance_of_asset<WETH>() == 0, 0);
        assert!(balance_of_shadow<WETH>() == 0, 0);

        collect_asset_fee<WETH>(coin::withdraw<WETH>(account, 200));
        assert!(balance_of_asset<WETH>() == 200, 0);
        assert!(balance_of_shadow<WETH>() == 0, 0);
        assert!(coin::balance<WETH>(account_address) == 800, 0);
        assert!(coin::balance<USDZ>(account_address) == 500, 0);
        assert!(coin::balance<WETH>(owner_address) == 0, 0);
        assert!(coin::balance<USDZ>(owner_address) == 0, 0);

        collect_shadow_fee<WETH>(coin::withdraw<USDZ>(account, 100));
        assert!(balance_of_asset<WETH>() == 200, 0);
        assert!(balance_of_shadow<WETH>() == 100, 0);
        assert!(coin::balance<WETH>(account_address) == 800, 0);
        assert!(coin::balance<USDZ>(account_address) == 400, 0);
        assert!(coin::balance<WETH>(owner_address) == 0, 0);
        assert!(coin::balance<USDZ>(owner_address) == 0, 0);

        withdraw_asset_fee<WETH>(owner, 150);
        assert!(balance_of_asset<WETH>() == 50, 0);
        assert!(balance_of_shadow<WETH>() == 100, 0);
        assert!(coin::balance<WETH>(account_address) == 800, 0);
        assert!(coin::balance<USDZ>(account_address) == 400, 0);
        assert!(coin::balance<WETH>(owner_address) == 150, 0);
        assert!(coin::balance<USDZ>(owner_address) == 0, 0);

        withdraw_shadow_fee<WETH>(owner, 75);
        assert!(balance_of_asset<WETH>() == 50, 0);
        assert!(balance_of_shadow<WETH>() == 25, 0);
        assert!(coin::balance<WETH>(account_address) == 800, 0);
        assert!(coin::balance<USDZ>(account_address) == 400, 0);
        assert!(coin::balance<WETH>(owner_address) == 150, 0);
        assert!(coin::balance<USDZ>(owner_address) == 75, 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_withdraw_asset_fee_with_not_owner(account: &signer) acquires Treasury {
        withdraw_asset_fee<WETH>(account, 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_withdraw_shadow_fee_with_not_owner(account: &signer) acquires Treasury {
        withdraw_shadow_fee<WETH>(account, 0);
    }
}
