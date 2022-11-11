// HACK: duplicated to leizd-aptos-core
module leizd_aptos_trove::liquidation_manager {
    use leizd_aptos_common::permission;
    use std::signer;

    struct SystemSnapshot has key {
        total_stake: u64,
        total_collateral: u64
    }

    struct UserStake has key {
        value: u64
    }

    fun remove_stake(account: address) acquires UserStake, SystemSnapshot {
        let stake = borrow_global_mut<UserStake>(account);
        let system_snapshot = borrow_global_mut<SystemSnapshot>(permission::owner_address());
        system_snapshot.total_stake = system_snapshot.total_stake - stake.value;
        stake.value = 0
    }

   fun update_stake_of(account: &signer, key: String, new_collateral: u64) acquires UserStake, SystemSnapshot {
        let account_addr = signer::address_of(account);
        if (!exists<UserStake>(signer::address_of(account))) {
            move_to(account, UserStake {
                value: 0,
            })
        };
        let old_stake = borrow_global<UserStake>(account_addr).value;
        let new_stake = compute_new_stake(new_collateral);
        borrow_global_mut<UserStake>(account_addr).value = new_stake;
        let snapshot =  borrow_global_mut<SystemSnapshot>(permission::owner_address());
        snapshot.total_stake = snapshot.total_stake - old_stake + new_stake
   }

   fun compute_new_stake(collateral: u64): u64 acquires SystemSnapshot {
        let stake = 0;
        let system_snapshot = borrow_global<SystemSnapshot>(permission::owner_address()); 
        if (system_snapshot.total_stake == 0) {
            return collateral;
        };
        collateral * system_snapshot.total_stake / system_snapshot.total_collateral
   }



}
