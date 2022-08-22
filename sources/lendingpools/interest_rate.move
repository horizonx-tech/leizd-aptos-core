module leizd::interest_rate {
    use std::signer;
    use aptos_framework::event;
    use leizd::math;
    use leizd::prb_math_30x9;
    use leizd::permission;

    friend leizd::pool;

    /// DP is 9 decimal points used for integer calculations
    const DP: u128 = 1000000000;

    const RCOMP_MAX: u128 = 65536000000000;

    /// TODO: X_MAX = ln(RCOMP_MAX + 1)
    const X_MAX: u128 = 11090370147631773313;

    struct Config<phantom C> has copy, drop, key {
        uopt: u128,
        ucrit: u128,
        ulow: u128,
        ki: u128,
        kcrit: u128,
        klow: u128,
        klin: u128,
        beta: u128,
        ri: u128,
        tcrit: u128
    }

    struct SetConfigEvent has store, drop {
        caller: address,
        uopt: u128,
        ucrit: u128,
        ulow: u128,
        ki: u128,
        kcrit: u128,
        klow: u128,
        klin: u128,
        beta: u128,
        ri: u128,
        tcrit: u128
    }

    struct InterestRateEventHandle<phantom C> has key, store {
        set_config_event: event::EventHandle<SetConfigEvent>,
    }

    public(friend) entry fun initialize<C>(owner: &signer) {
        let config = default_config<C>();
        assert_config(config);

        move_to(owner, config);
        move_to(owner, InterestRateEventHandle<C> {
            set_config_event: event::new_event_handle<SetConfigEvent>(owner)
        });
    }
    
    public fun default_config<C>(): Config<C> {
        Config<C> {
            uopt: 800000000,  // 80%
            ucrit: 900000000, // 90%
            ulow: 500000000,  // 50%
            ki: 367011,
            kcrit: 951293759513, // TODO
            klow: 95129375951,
            klin: 1585489599,
            beta: 277777777777778,
            ri: 0,
            tcrit: 0,
        }
    }

    public fun config<C>(): Config<C> acquires Config {
        *borrow_global<Config<C>>(@leizd)
    }

    fun assert_config<C>(config: Config<C>) {
        assert!(config.uopt > 0 && config.uopt < DP, 0);
        assert!(config.ucrit > config.uopt && config.ucrit < DP, 0);
        assert!(config.ulow > 0 && config.ulow < config.uopt, 0);
        assert!(config.ki > 0, 0);
        assert!(config.kcrit > 0, 0);
    }

    public fun set_config<C>(owner: &signer, config: Config<C>) acquires Config, InterestRateEventHandle {
        permission::assert_owner(signer::address_of(owner));
        assert_config(config);

        let config_ref = borrow_global_mut<Config<C>>(@leizd);
        config_ref.uopt = config.uopt;
        config_ref.ucrit = config.ucrit;
        config_ref.ulow = config.ulow;
        config_ref.ki = config.ki;
        config_ref.kcrit = config.kcrit;
        config_ref.klow = config.klow;
        config_ref.klin = config.klin;
        config_ref.beta = config.beta;
        config_ref.ri = config.ri;
        config_ref.tcrit = config.tcrit;
        event::emit_event<SetConfigEvent>(
            &mut borrow_global_mut<InterestRateEventHandle<C>>(@leizd).set_config_event,
            SetConfigEvent {
                caller: signer::address_of(owner),
                uopt: config.uopt,
                ucrit: config.ucrit,
                ulow: config.ulow,
                ki: config_ref.ki,
                kcrit: config_ref.kcrit,
                klow: config_ref.klow,
                klin: config_ref.klin,
                beta: config_ref.beta,
                ri: config_ref.ri,
                tcrit: config_ref.tcrit,
            }
        )
    }

    public(friend) fun update_interest_rate<C>(now: u64, total_deposits: u128, total_borrows: u128, last_updated: u64): u64 acquires Config {
        let config_ref = borrow_global_mut<Config<C>>(@leizd);
        let (rcomp,_,_,_) = calc_compound_interest_rate<C>(config_ref, total_deposits, total_borrows, last_updated, now);
        rcomp
    }

    fun slope_index(ki: u128, u0: u128, uopt: u128): (u128, bool) {
        if (u0 >= uopt) {
            (ki * (u0 - uopt) / DP, true)
        } else {
            (ki * (uopt - u0) / DP, false)
        }
    }

    public fun calc_compound_interest_rate<C>(config_ref: &Config<C>, total_deposits: u128, total_borrows: u128, last_updated: u64, now: u64): (u64, u64, u64, bool) {
        let time = ((now - last_updated) as u128);
        let u = math::utilization(total_deposits, total_borrows);
        let (slope_i, slope_i_positive) = slope_index(config_ref.ki, u, config_ref.uopt);
        
        let ri = config_ref.ri;
        let tcrit = config_ref.tcrit;
        let rp;
        let slope;
        
        if (u > config_ref.ucrit) {
            rp = config_ref.kcrit * (DP + config_ref.tcrit) / DP * (u - config_ref.ucrit) / DP;
            if (slope_i_positive) {
                slope = slope_i + config_ref.kcrit * config_ref.beta / DP * (u - config_ref.ucrit) / DP;
            } else {
                slope = config_ref.kcrit * config_ref.beta / DP * (u - config_ref.ucrit) / DP - slope_i;
            };
            tcrit = tcrit + config_ref.beta * time;
        } else {
            if (config_ref.ulow >= u) {
                // TODO: min?
                let rp_tmp = config_ref.kcrit * (config_ref.ulow - u) / DP;
                rp = math::min_u128(0, rp_tmp);
            } else {
                let rptmp = config_ref.kcrit * (u - config_ref.ulow) / DP;
                rp = math::min_u128(0, rptmp);
            };
            
            slope = slope_i;
            tcrit = math::max_u128(0, tcrit - config_ref.beta * time);
        };
        
        let rlin = config_ref.klin * u / DP;
        ri = math::max_u128(ri, rlin);
        let r0 = ri + rp;
        let r1 = r0 + slope * time;

        let x;
        if (r0 >= rlin && r1 >= rlin) {
            x = (r0 + r1) * time / 2;
        } else if (r0 < rlin && r1 < rlin) {
            x = rlin * time;
        } else if (r0 >= rlin && r1 < rlin) {
            x = rlin * time - (r0 - rlin) * (r0 - rlin) / slope / 2;
        } else {
            x = rlin * time + (r1 - rlin) * (r1 - rlin) / slope / 2;
        };

        ri = math::max_u128(ri + slope_i * time, rlin);
        let (rcomp, overflow) = calc_rcomp(total_deposits, total_borrows, x);

        if (overflow) {
            ri = 0;
            tcrit = 0;
        };

        ((rcomp as u64), (ri as u64), (tcrit as u64), overflow)
    }

    fun calc_rcomp(total_deposits: u128, total_borrows: u128, x: u128): (u128,bool) {

        let rcomp;
        let overflow = false;
        if (x >= X_MAX) {
            rcomp = (math::pow(2, 16) as u128) * DP;
            overflow = true;
        } else {
            // TODO: exp
            let expx = prb_math_30x9::exp((x as u128));
            if (expx > (DP as u128)) {
                rcomp = expx;
            } else {
                rcomp = 0;
            };
            total_deposits;
            total_borrows;
            // TODO MAX AMOUNT
            // let max_amount = if (total_deposits > total_borrows) total_deposits else total_borrows;
            // let rcomp_mul_tba = (rcomp as u128) * total_borrows;
        };

        (rcomp, overflow)
    }

}