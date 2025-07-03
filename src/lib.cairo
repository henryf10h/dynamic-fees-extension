mod contracts {
    mod memecoin;
    mod relaunch;
    pub mod position_manager;
    pub mod internal_swap_pool;
    pub mod router;
    pub mod test_token;
}

mod interfaces {
    pub mod Iisp;
    pub mod Iposition_manager;
    pub mod Imemecoin;
    pub mod Irelaunch;
    pub mod Irouter;
}

#[cfg(test)]
mod tests{
    pub mod router_swap_test;
}


