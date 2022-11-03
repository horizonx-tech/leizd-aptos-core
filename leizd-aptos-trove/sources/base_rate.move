// HACK: duplicated to leizd-aptos-core
module leizd_aptos_trove::base_rate {
    friend leizd_aptos_trove::trove;
    use aptos_framework::timestamp;
    use leizd_aptos_common::permission;
    use leizd_aptos_lib::math128;
    use leizd_aptos_trove::base_rate_calculator;

    /*
     * Half-life of 12h. 12h = 720 min
     * (1/2) = d^720 => d = (1/2)^(1/720) with 6 digits.
     */
    const MINUTE_DECAY_FACTOR: u64 = 999037;
    const PRECISION: u64 = 1000000;

    /*
    * BETA: 6 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
    * Represents 1/2 with 6 digits.
    */
    const BETA: u128 = 2;

    const MICROSECONDS_IN_MINUTE: u64 = 60 * 1000000;

    struct BaseRate has key {
        rate: u128,
    }

    struct FeeOperationTime has key {
        last_operation_time_micro_seconds: u64
    }

    public fun precision(): u64 {
        PRECISION
    }

    public(friend) fun initialize(owner: &signer) {
        move_to(owner, BaseRate {
            rate: 0,
        });
        move_to(owner, FeeOperationTime {
            last_operation_time_micro_seconds: 0
        })
    }

    public fun base_rate(): u128 acquires BaseRate {
        borrow_global<BaseRate>(permission::owner_address()).rate
    }

    public(friend) fun update_base_rate_from_redemption(redeemed_amount_in_usdz: u64, total_usdz_supply: u64) acquires FeeOperationTime, BaseRate {
        let decayed_base_rate = calc_decayed_base_rate();
        let redeemed_usdz_fraction = ((redeemed_amount_in_usdz as u128) * (PRECISION as u128)) / (total_usdz_supply as u128);
        let new_base_rate = decayed_base_rate + (redeemed_usdz_fraction / BETA);
        new_base_rate = math128::min(new_base_rate, (PRECISION as u128));
        assert!((new_base_rate as u64) > 0, (new_base_rate as u64));
        borrow_global_mut<BaseRate>(permission::owner_address()).rate = new_base_rate;
        update_last_fee_operation_time()
    }

    public(friend) fun decay_base_rate_from_borrowing() acquires FeeOperationTime, BaseRate {
        let decayed_base_rate = calc_decayed_base_rate();
        assert!((decayed_base_rate) <= (PRECISION as u128), 0); // TODO: error code
        borrow_global_mut<BaseRate>(permission::owner_address()).rate = decayed_base_rate;
        update_last_fee_operation_time()
    }

    fun update_last_fee_operation_time() acquires FeeOperationTime {
        let last_fee_operation_time = borrow_global_mut<FeeOperationTime>(permission::owner_address());
        let passed_in_minute = minutes_time_passed_from(last_fee_operation_time.last_operation_time_micro_seconds);
        if (passed_in_minute == 0) {
            return
        };
        last_fee_operation_time.last_operation_time_micro_seconds = timestamp::now_microseconds()
    }

    public fun calc_decayed_base_rate(): u128 acquires FeeOperationTime, BaseRate {
        let minutes_passed = minutes_passed_since_last_fee_operation();
        let decay_factor = base_rate_calculator::dec_pow(MINUTE_DECAY_FACTOR, minutes_passed);
        (borrow_global<BaseRate>(permission::owner_address()).rate as u128) * decay_factor / (PRECISION as u128)
    }

    fun minutes_passed_since_last_fee_operation(): u64 acquires FeeOperationTime {
        minutes_time_passed_from(borrow_global<FeeOperationTime>(permission::owner_address()).last_operation_time_micro_seconds)
    }

    fun minutes_time_passed_from(from: u64): u64 {
        (timestamp::now_microseconds() - from) / MICROSECONDS_IN_MINUTE
    }

    #[test_only]
    use std::signer;

    #[test_only]
    public fun set_up(owner: &signer, aptos_framework: &signer) {
        initialize(owner);
        timestamp::set_time_has_started_for_testing(aptos_framework);
    }

    #[test(owner=@leizd_aptos_trove,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_update_base_rate_from_redemption(owner: &signer, aptos_framework: &signer) acquires BaseRate, FeeOperationTime {
        set_up(owner, aptos_framework);
        let now = 1662125899730897;
        let one_minute = 60 * 1000 * 1000;
        timestamp::update_global_time_for_test(now);
        decay_base_rate_from_borrowing();
        timestamp::update_global_time_for_test(now + one_minute * 10);
        update_base_rate_from_redemption(10 * 100000, 100 * 100000);
        let new_rate = borrow_global<BaseRate>(signer::address_of(owner)).rate;
        // TODO: add tests
        assert!(new_rate == 50000, (new_rate as u64));
    }

}
