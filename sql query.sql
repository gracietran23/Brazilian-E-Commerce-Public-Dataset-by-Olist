-- A. Check and convert data type
ALTER TABLE orders ALTER COLUMN order_purchase_timestamp DATETIME;
ALTER TABLE orders ALTER COLUMN order_approved_at DATETIME;
ALTER TABLE orders ALTER COLUMN order_delivered_carrier_date DATETIME;
ALTER TABLE orders ALTER COLUMN order_delivered_customer_date DATETIME;
ALTER TABLE orders ALTER COLUMN order_estimated_delivery_date DATETIME;


-- B. SQL query
-- 1. Monthly revenue trend
with monthly_revenue as(
	select 
		year(order_purchase_timestamp) as y, 
		month(order_purchase_timestamp) as m, 
		sum(price + freight_value) as monthly_sales
	from orders o 
	join order_items i on o.order_id = i.order_id
	WHERE order_status = 'delivered'
	group by year(order_purchase_timestamp), month(order_purchase_timestamp)
)
select 
	y,
	m,
	monthly_sales,
	round(((monthly_sales - lag(monthly_sales) over (order by y,m))
	/ (lag(monthly_sales) over (order by y,m)) * 100),3) as 'growth_rate (%)'
	
from monthly_revenue;


-- 2. Top 5 category products contributing to the highest revenue, group by year
with rank_revenue as(
	select 
		year(order_purchase_timestamp) as y, 
		p.product_category_name_english as category, 
		sum(price + freight_value) as total_sales,
		RANK() OVER(
			PARTITION BY year(order_purchase_timestamp) 
			ORDER BY sum(price + freight_value) DESC
		) as rank_prod 
	from orders o 
	join customers c on o.customer_id = c.customer_id
	join order_items i on o.order_id = i.order_id
	join products p on p.product_id = i.product_id
	WHERE order_status = 'delivered'
	group by year(order_purchase_timestamp), p.product_category_name_english
)
select y, category, total_sales,rank_prod
from rank_revenue r
where rank_prod <= 5

WITH rank_revenue AS (
    SELECT 
        order_year AS y, 
        product_category_name_english AS category, 
        SUM(total_sales) AS revenue, -- Tính t?ng doanh thu
        RANK() OVER (
            PARTITION BY order_year 
            ORDER BY SUM(total_sales) DESC
        ) AS rank_prod 
    FROM v_Master_Sales_Operations
    GROUP BY order_year, product_category_name_english
)
SELECT y, category, revenue, rank_prod
FROM rank_revenue
WHERE rank_prod <= 3
ORDER BY y ASC, rank_prod ASC;


-- 3. Revenue of each city and its proportion over the country
select 
	c.customer_state as state, 
	sum(i.price + i.freight_value) as revenue_by_state, 
	sum(i.price + i.freight_value) / SUM(SUM(i.price + i.freight_value)) OVER() * 100 AS percentage_account_for
from orders o 
join customers c on c.customer_id = o.customer_id
join order_items i on i.order_id = o.order_id 
where order_status = 'delivered'
group by c.customer_state
order by revenue_by_state desc;


-- 4. Delivery delay analysis, which city has the highest delay rate
select 
	c.customer_state, 
	avg(cast(datediff(day, order_purchase_timestamp, order_delivered_customer_date) as float)) as avg_deliver_date,
	avg(cast(datediff(day, order_delivered_customer_date, order_estimated_delivery_date) as float)) as avg_delay_rate
from orders o
join customers c on c.customer_id = o.customer_id
where order_status = 'delivered'
and order_delivered_customer_date is not null
group by c.customer_state
order by avg_delay_rate desc


-- 5. Delay vs Review
SELECT 
    o.order_id,
    o.order_purchase_timestamp,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    DATEDIFF(day, o.order_purchase_timestamp, o.order_delivered_customer_date) AS actual_delivery_time,
    DATEDIFF(day, o.order_estimated_delivery_date, o.order_delivered_customer_date) AS delivery_delay,
    CASE 
        WHEN DATEDIFF(day, o.order_estimated_delivery_date, o.order_delivered_customer_date) > 0 THEN 'Late'
        ELSE 'On-time/Early'
    END AS delivery_status,
    r.review_score
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
LEFT JOIN order_reviews r ON o.order_id = r.order_id
WHERE o.order_status = 'delivered' 
  AND o.order_delivered_customer_date IS NOT NULL
  and DATEDIFF(day, o.order_estimated_delivery_date, o.order_delivered_customer_date) < -100;


-- 6. Recency, frequency, monetary of each customer
use Olist_DB
with count_sum_purchase as(
	select c.customer_unique_id, max(order_purchase_timestamp) as last_date_purchase, count(distinct o.order_id) as total_orders_purchase, sum(price + freight_value) as total_money_spend
	from customers c join orders o on c.customer_id = o.customer_id
	join order_items i on i.order_id = o.order_id
	group by c.customer_unique_id
)
select 
	customer_unique_id, 
	last_date_purchase as recency,
	total_orders_purchase as frequency,
	total_money_spend as monetary 
from count_sum_purchase cs
order by total_orders_purchase desc


-- 7. Retention rate of top 10 city
with customer_stats as(
	select 
		customer_city,
		customer_unique_id,
        COUNT(order_id) AS orders_per_customer
    FROM customers c
    JOIN orders o ON c.customer_id = o.customer_id
    GROUP BY customer_city, customer_unique_id
),
retention_rate_per_city as(
	select 
		customer_city,
		count(customer_unique_id) as total_customers,
		SUM(CASE WHEN orders_per_customer >= 2 THEN 1 ELSE 0 END) AS returning_customers
	from customer_stats
	group by customer_city
),
top_10_most_crowded_city as(
	select 
		customer_city, 
		total_customers, 
		returning_customers, 
		rank() over(order by total_customers desc) as city_rank
	from retention_rate_per_city
)

select 
	customer_city, 
	total_customers,
	cast(returning_customers * 100.0 / total_customers AS DECIMAL(10, 2)) as retention_rate_percentage
from top_10_most_crowded_city
WHERE city_rank <= 10
order by retention_rate_percentage desc


-- 8. Golden hour
SELECT 
    DATEPART(HOUR, o.order_purchase_timestamp) AS purchase_hour,
    COUNT(o.order_id) AS total_orders,
    AVG(p.total_payment) AS avg_order_value
FROM orders o
JOIN (
    SELECT order_id, SUM(payment_value) AS total_payment 
    FROM order_payments 
    GROUP BY order_id
) p ON o.order_id = p.order_id
WHERE o.order_status != 'canceled'
GROUP BY DATEPART(HOUR, o.order_purchase_timestamp)
ORDER BY total_orders desc;


-- 9. Delivery Status vs Review Score
SELECT 
    review_score,
    delivery_state,
    COUNT(order_id) AS total_orders,
    ROUND(
        COUNT(order_id) * 100.0 / SUM(COUNT(order_id)) OVER (PARTITION BY review_score), 
        2
    ) AS percentage
FROM (
    SELECT 
        o.order_id, 
        review_score,
        CASE 
            WHEN order_delivered_customer_date <= order_estimated_delivery_date THEN 'On time/Early'
            ELSE 'Late'
        END AS delivery_state
    FROM orders o join order_reviews r on o.order_id = r.order_id
	where order_delivered_customer_date is not null
	
) AS subquery
GROUP BY 
    review_score, 
    delivery_state
ORDER BY 
    review_score DESC, 
    delivery_state;

SELECT o.order_id, o.order_delivered_customer_date, o.order_estimated_delivery_date, r.review_score
FROM orders o 
JOIN order_reviews r ON o.order_id = r.order_id


-- 10. Seller with the most low-rating score
select 
	seller_id, 
	count(distinct i.order_id) as number_of_orders, 
	avg(cast(r.review_score as decimal(10,2))) as avg_review_score
from order_items i 
join order_reviews r on r.order_id = i.order_id
group by seller_id
HAVING COUNT(DISTINCT i.order_id) >= 10
order by avg_review_score